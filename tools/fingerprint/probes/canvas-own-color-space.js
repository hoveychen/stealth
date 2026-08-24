// A display-p3 canvas: what its bitmap *stores*, and what the paint state
// reads back while it does.
//
// The two halves pull apart. `fillStyle` answers the notation it was given —
// a display-p3 canvas does not restate `#ff0000` as the p3 byte triple — while
// the bytes behind it are the canvas's own space. So the context cannot keep
// one RGBA and serve both; a probe that only reads `fillStyle` back sees
// nothing at all.
(() => {
  const ask = (f) => { try { return f(); } catch (e) { return `throw:${e.name}: ${e.message}`; } };
  const hex = (d) => [...d].map((b) => b.toString(16).padStart(2, '0')).join('');
  const ctx = (space) => new OffscreenCanvas(1, 1).getContext('2d', {
    colorSpace: space,
    willReadFrequently: true,
  });

  // Painted in `notation` on a canvas of `space`, read back in every space.
  const stored = {};
  const notations = [
    '#ff0000',
    'color(display-p3 1 0.25 0.5)',
    'rgb(255, 27, 127)',
    'rgba(255, 0, 0, 0.5)',
    'lab(50% 40 59.5)',
    'oklch(0.7 0.1 200)',
    'color(srgb 1 0.25 0.5)',
    'color(rec2020 1 0.25 0.5)',
    'white',
  ];
  for (const space of ['srgb', 'display-p3']) {
    for (const notation of notations) {
      stored[`${space} | ${notation}`] = ask(() => {
        const c = ctx(space);
        c.fillStyle = notation;
        c.fillRect(0, 0, 1, 1);
        const read = (cs) => hex(c.getImageData(0, 0, 1, 1, { colorSpace: cs }).data);
        // The paint state's own answer, which is a separate question.
        return `default=${hex(c.getImageData(0, 0, 1, 1).data)} srgb=${read('srgb')} p3=${read('display-p3')} fillStyle=${c.fillStyle}`;
      });
    }
  }

  // The rest of the paint state on a display-p3 canvas.
  const rest = {};
  rest['strokeStyle'] = ask(() => {
    const c = ctx('display-p3');
    c.strokeStyle = '#ff0000';
    c.lineWidth = 2;
    c.strokeRect(0, 0, 1, 1);
    return `${hex(c.getImageData(0, 0, 1, 1).data)} strokeStyle=${c.strokeStyle}`;
  });
  rest['clearRect'] = ask(() => {
    const c = ctx('display-p3');
    c.fillStyle = '#ff0000';
    c.fillRect(0, 0, 1, 1);
    c.clearRect(0, 0, 1, 1);
    return hex(c.getImageData(0, 0, 1, 1).data);
  });
  rest['untouched'] = ask(() => hex(ctx('display-p3').getImageData(0, 0, 1, 1).data));
  rest['globalAlpha'] = ask(() => {
    const c = ctx('display-p3');
    c.globalAlpha = 0.5;
    c.fillStyle = '#ff0000';
    c.fillRect(0, 0, 1, 1);
    return hex(c.getImageData(0, 0, 1, 1).data);
  });
  // Save/restore carries the style across, whatever space the canvas is in.
  rest['save/restore'] = ask(() => {
    const c = ctx('display-p3');
    c.fillStyle = 'color(display-p3 1 0.25 0.5)';
    c.save();
    c.fillStyle = '#00ff00';
    c.restore();
    c.fillRect(0, 0, 1, 1);
    return `${hex(c.getImageData(0, 0, 1, 1).data)} fillStyle=${c.fillStyle}`;
  });
  // Resizing resets the bitmap but not the space.
  rest['resize keeps the space'] = ask(() => {
    const c = new OffscreenCanvas(1, 1);
    const g = c.getContext('2d', { colorSpace: 'display-p3', willReadFrequently: true });
    c.width = 2;
    g.fillStyle = '#ff0000';
    g.fillRect(0, 0, 1, 1);
    return `${hex(g.getImageData(0, 0, 1, 1).data)} ${g.getContextAttributes().colorSpace}`;
  });

  // Crossing spaces: what a canvas paints from *another* canvas, and what its
  // PNG carries. Both are scope questions rather than assertions.
  const crossing = {};
  crossing['drawImage p3 -> srgb'] = ask(() => {
    const source = new OffscreenCanvas(1, 1);
    const sg = source.getContext('2d', { colorSpace: 'display-p3' });
    sg.fillStyle = 'color(display-p3 1 0.25 0.5)';
    sg.fillRect(0, 0, 1, 1);
    const dest = ctx('srgb');
    dest.drawImage(source, 0, 0);
    return hex(dest.getImageData(0, 0, 1, 1).data);
  });
  crossing['drawImage srgb -> p3'] = ask(() => {
    const source = new OffscreenCanvas(1, 1);
    const sg = source.getContext('2d');
    sg.fillStyle = '#ff0000';
    sg.fillRect(0, 0, 1, 1);
    const dest = ctx('display-p3');
    dest.drawImage(source, 0, 0);
    return hex(dest.getImageData(0, 0, 1, 1).data);
  });

  // Whose space an *absent* `colorSpace` member means. Not srgb: both canvas
  // entry points default to the canvas's own space, and only an explicit value
  // overrides it. `new ImageData` has no canvas and does default to srgb.
  const defaults = {};
  {
    const p3 = () => {
      const g = ctx('display-p3');
      g.fillStyle = '#ff0000';
      g.fillRect(0, 0, 1, 1);
      return g;
    };
    const show = (d) => `${hex(d.data)} ${d.colorSpace} ${d.pixelFormat}`;
    defaults['getImageData no settings'] = ask(() => show(p3().getImageData(0, 0, 1, 1)));
    defaults['getImageData {}'] = ask(() => show(p3().getImageData(0, 0, 1, 1, {})));
    defaults['getImageData {colorSpace: undefined}'] =
      ask(() => show(p3().getImageData(0, 0, 1, 1, { colorSpace: undefined })));
    defaults['getImageData []'] = ask(() => show(p3().getImageData(0, 0, 1, 1, [])));
    defaults['getImageData null'] = ask(() => show(p3().getImageData(0, 0, 1, 1, null)));
    defaults['getImageData {colorSpace: srgb}'] =
      ask(() => show(p3().getImageData(0, 0, 1, 1, { colorSpace: 'srgb' })));
    defaults['getImageData {pixelFormat only}'] =
      ask(() => show(p3().getImageData(0, 0, 1, 1, { pixelFormat: 'rgba-unorm8' })));
    defaults['createImageData no settings'] = ask(() => {
      const d = p3().createImageData(1, 1);
      return `${d.colorSpace} ${d.pixelFormat} len=${d.data.length}`;
    });
    defaults['createImageData {}'] = ask(() => p3().createImageData(1, 1, {}).colorSpace);
    defaults['createImageData {colorSpace: srgb}'] =
      ask(() => p3().createImageData(1, 1, { colorSpace: 'srgb' }).colorSpace);
    // A source ImageData's own settings win over the canvas's.
    defaults['createImageData from srgb ImageData'] =
      ask(() => p3().createImageData(new ImageData(2, 2)).colorSpace);
    defaults['new ImageData no settings'] = ask(() => new ImageData(1, 1).colorSpace);
    defaults['srgb canvas getImageData no settings'] =
      ask(() => show(ctx('srgb').getImageData(0, 0, 1, 1)));
    defaults['srgb canvas createImageData no settings'] =
      ask(() => ctx('srgb').createImageData(1, 1).colorSpace);
  }

  return { stored, rest, crossing, defaults };
})()
