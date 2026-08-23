// What an ImageBitmap carries, beyond its width and height.
//
// The first half of this ground truth already lives in
// src/browser/tests/window/image_bitmap.html; this probe covers the cases that
// block landing the pixel snapshot and were not measured there: the wording of
// the detached-source throw on each of the two 2D context interfaces, whether
// an ImageData source carries its pixels, and what a crop rect that runs off
// the source (or runs backwards) picks up.
(async () => {
  const out = {};
  const hex = (d) => { let s = ''; for (let i = 0; i < d.length; i++) s += d[i].toString(16).padStart(2, '0'); return s; };
  const rec = async (key, fn) => {
    try { out[key] = await fn(); } catch (e) { out[key] = e.name + ': ' + e.message; }
  };

  // A 4x2 source: red over the left half, blue over the right.
  const src = document.createElement('canvas');
  src.width = 4; src.height = 2;
  const sc = src.getContext('2d');
  sc.fillStyle = '#ff0000'; sc.fillRect(0, 0, 2, 2);
  sc.fillStyle = '#0000ff'; sc.fillRect(2, 0, 2, 2);

  const into = (w, h, fn) => {
    const c = document.createElement('canvas');
    c.width = w; c.height = h;
    const g = c.getContext('2d');
    fn(g);
    return hex(g.getImageData(0, 0, w, h).data);
  };
  const intoOffscreen = (w, h, fn) => {
    const c = new OffscreenCanvas(w, h);
    const g = c.getContext('2d');
    fn(g);
    return hex(g.getImageData(0, 0, w, h).data);
  };

  // 1) The detached throw, once per 2D context interface. Chrome names the
  //    receiver's interface in the message, so the two are expected to differ
  //    -- which is the whole reason for measuring both.
  await rec('detachedOnCanvas2d', async () => {
    const b = await createImageBitmap(src);
    b.close();
    return into(4, 2, (g) => g.drawImage(b, 0, 0));
  });
  await rec('detachedOnOffscreen2d', async () => {
    const b = await createImageBitmap(src);
    b.close();
    return intoOffscreen(4, 2, (g) => g.drawImage(b, 0, 0));
  });

  // 2) An ImageData source. The in-repo test names a case `fromImageData` but
  //    actually re-draws the canvas-sourced bitmap, so this is unmeasured.
  await rec('fromImageData', async () => {
    const data = sc.getImageData(0, 0, 4, 2);
    const b = await createImageBitmap(data);
    return { size: [b.width, b.height], pixels: into(4, 2, (g) => g.drawImage(b, 0, 0)) };
  });

  // 3) An OffscreenCanvas source, drawn back into an element canvas.
  await rec('fromOffscreen', async () => {
    const oc = new OffscreenCanvas(4, 2);
    const og = oc.getContext('2d');
    og.fillStyle = '#00ff00'; og.fillRect(0, 0, 4, 1);
    const b = await createImageBitmap(oc);
    return into(4, 2, (g) => g.drawImage(b, 0, 0));
  });

  // 4) Crop rects that leave the source: past the right edge, starting
  //    negative, and running backwards. The bitmap keeps the requested size in
  //    every case (already measured); what the pixels are is not.
  await rec('cropPastRight', async () => {
    const b = await createImageBitmap(src, 3, 0, 2, 2);
    return { size: [b.width, b.height], pixels: into(2, 2, (g) => g.drawImage(b, 0, 0)) };
  });
  await rec('cropNegativeOrigin', async () => {
    const b = await createImageBitmap(src, -1, 0, 2, 2);
    return { size: [b.width, b.height], pixels: into(2, 2, (g) => g.drawImage(b, 0, 0)) };
  });
  await rec('cropBackwards', async () => {
    const b = await createImageBitmap(src, 4, 2, -2, -2);
    return { size: [b.width, b.height], pixels: into(2, 2, (g) => g.drawImage(b, 0, 0)) };
  });

  // 5) A bitmap taken from a canvas that only ever had a WebGL context. The
  //    engine rasterises nothing there, so knowing whether Chrome's bitmap is
  //    transparent or the cleared colour decides whether that is a gap.
  await rec('fromWebglCanvas', async () => {
    const c = document.createElement('canvas');
    c.width = 2; c.height = 1;
    const gl = c.getContext('webgl');
    if (!gl) return 'no webgl';
    gl.clearColor(1, 0, 0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
    const b = await createImageBitmap(c);
    return into(2, 1, (g) => g.drawImage(b, 0, 0));
  });

  // 6) drawImage of a bitmap under a transform, to confirm the bitmap goes
  //    through the same path a canvas source does.
  await rec('scaledUp', async () => {
    const b = await createImageBitmap(src, 0, 0, 2, 2);
    return into(4, 2, (g) => g.drawImage(b, 0, 0, 4, 2));
  });

  return JSON.stringify(out);
})()
