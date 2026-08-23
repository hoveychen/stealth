// What OffscreenCanvas.transferToImageBitmap() answers, and what it leaves
// behind.
//
// The challenge widget takes two independent routes to an ImageBitmap of the
// same 49x44 render -- this one, synchronous, and createImageBitmap(oc),
// asynchronous -- and reads each back. This engine answers null here (a stub
// left from before ImageBitmap existed), so the first route never starts.
// Implementing it needs more than "return the pixels": the name says transfer,
// and what the source canvas is afterwards decides whether the second route
// still has anything to photograph.
//
// Measured with run-expr.mjs, which drives Chrome with --headless=new. Nothing
// here reaches the compositor -- it is 2D raster, an exception message and an
// object identity -- so headless is a sound oracle for it.
(async () => {
  const out = {};
  const hex = (d) => { let s = ''; for (let i = 0; i < d.length; i++) s += d[i].toString(16).padStart(2, '0'); return s; };
  const rec = async (key, fn) => {
    try { out[key] = await fn(); } catch (e) { out[key] = e.name + ': ' + e.message; }
  };

  // A 2x1 source: red then blue, so a blank canvas is unmistakable.
  const painted = (w, h) => {
    const oc = new OffscreenCanvas(w, h);
    const g = oc.getContext('2d');
    g.fillStyle = '#ff0000'; g.fillRect(0, 0, 1, h);
    g.fillStyle = '#0000ff'; g.fillRect(1, 0, w - 1, h);
    return { oc, g };
  };
  const shot = (bmp, w, h) => {
    const c = new OffscreenCanvas(w, h);
    const g = c.getContext('2d');
    g.drawImage(bmp, 0, 0);
    return hex(g.getImageData(0, 0, w, h).data);
  };

  // 1) The return value itself.
  await rec('returns', () => {
    const { oc } = painted(2, 1);
    const b = oc.transferToImageBitmap();
    return {
      ctor: b && b.constructor ? b.constructor.name : String(b),
      tag: Object.prototype.toString.call(b),
      size: [b.width, b.height],
      pixels: shot(b, 2, 1),
    };
  });

  // 2) What the source canvas holds afterwards -- the whole question behind
  //    the word "transfer". Read through the same 2D context, and again
  //    through a fresh createImageBitmap, in case only one of the two sees it.
  await rec('sourceAfter', async () => {
    const { oc, g } = painted(2, 1);
    oc.transferToImageBitmap();
    const viaContext = hex(g.getImageData(0, 0, 2, 1).data);
    const viaBitmap = shot(await createImageBitmap(oc), 2, 1);
    return { viaContext, viaBitmap, size: [oc.width, oc.height] };
  });

  // 3) Whether the context survives the transfer and can be drawn into again,
  //    and whether it still points back at the same canvas.
  await rec('contextAfter', () => {
    const { oc, g } = painted(2, 1);
    oc.transferToImageBitmap();
    const same = g.canvas === oc;
    g.fillStyle = '#00ff00'; g.fillRect(0, 0, 2, 1);
    return { canvasIdentity: same, redrawn: hex(g.getImageData(0, 0, 2, 1).data) };
  });

  // 4) Two transfers in a row: does the second answer a blank bitmap or throw?
  await rec('twice', () => {
    const { oc } = painted(2, 1);
    const first = shot(oc.transferToImageBitmap(), 2, 1);
    const second = shot(oc.transferToImageBitmap(), 2, 1);
    return { first, second };
  });

  // 5) No context at all. The spec says InvalidStateError; the wording is what
  //    has to be copied, and Chrome names the receiver's interface in it.
  await rec('noContext', () => {
    const oc = new OffscreenCanvas(2, 1);
    const b = oc.transferToImageBitmap();
    return { ctor: b && b.constructor ? b.constructor.name : String(b), size: [b.width, b.height] };
  });

  // 6) A canvas whose only context is WebGL -- this engine rasterises nothing
  //    there, so whether Chrome hands back the clear colour decides whether
  //    that is a second gap hiding behind the first.
  await rec('webglOnly', () => {
    const oc = new OffscreenCanvas(2, 1);
    const gl = oc.getContext('webgl');
    if (!gl) return 'no webgl';
    gl.clearColor(1, 0, 0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
    const b = oc.transferToImageBitmap();
    return { size: [b.width, b.height], pixels: shot(b, 2, 1) };
  });

  // 7) A bitmap context (transferFromImageBitmap's partner) as the source.
  await rec('bitmapContext', () => {
    const oc = new OffscreenCanvas(2, 1);
    const g = oc.getContext('bitmaprenderer');
    if (!g) return 'no bitmaprenderer';
    const b = oc.transferToImageBitmap();
    return { size: [b.width, b.height], pixels: shot(b, 2, 1) };
  });

  // 8) Zero extents. `new OffscreenCanvas(0, 1)` is legal, and getContext on it
  //    is where Chrome usually refuses -- so the transfer may never be reached.
  await rec('zeroWidth', () => {
    const oc = new OffscreenCanvas(0, 1);
    const g = oc.getContext('2d');
    const b = oc.transferToImageBitmap();
    return { gotContext: !!g, ctor: b && b.constructor ? b.constructor.name : String(b), size: [b.width, b.height] };
  });

  // 9) The transferred bitmap outliving a resize of its source, since a resize
  //    is how the widget recycles canvases.
  await rec('sourceResizedAfter', () => {
    const { oc } = painted(2, 1);
    const b = oc.transferToImageBitmap();
    oc.width = 4;
    return { size: [b.width, b.height], pixels: shot(b, 2, 1) };
  });

  // 10) close() on a transferred bitmap, to confirm it is an ordinary
  //     ImageBitmap and not something with its own lifetime rules.
  await rec('closeThenDraw', () => {
    const { oc } = painted(2, 1);
    const b = oc.transferToImageBitmap();
    b.close();
    return { size: [b.width, b.height], pixels: shot(b, 2, 1) };
  });

  return JSON.stringify(out);
})()
