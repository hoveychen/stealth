// What actually follows from devicePixelRatio, and what only looks like it does.
//
// x-hyatt's Kasada script reads `devicePixelRatio` eight times and then spends
// 314 media queries binary-searching the same number to twenty bits, so a
// persona that answers 1 where the browser clearing the station answers 2 is
// the widest single reading B53 found. Changing it is not one getter, though:
// a device pixel ratio is a claim about the relationship between two coordinate
// systems, and every reading that crosses between them has to move with it or
// the claim contradicts itself the way the 8-bit panel did.
//
// The way to find those readings without guessing is to hold everything else
// still and move only the ratio: run this twice against the *same* headless
// Chrome, once with `--force-device-scale-factor=1` and once with `=2`, same
// window size, same page. Whatever differs is the blast radius; whatever does
// not, is not.
(() => {
  const out = {};
  const call = (label, fn) => {
    try {
      const v = fn();
      out[label] = v === undefined ? 'undefined' : v === null ? 'null' : String(v);
    } catch (e) { out[label] = (e.name || 'Error') + ': ' + e.message; }
  };

  call('devicePixelRatio', () => devicePixelRatio);

  // The window and the screen, all of which are documented as CSS pixels.
  for (const n of ['innerWidth', 'innerHeight', 'outerWidth', 'outerHeight', 'screenX', 'screenY']) {
    call('window.' + n, () => self[n]);
  }
  for (const n of ['width', 'height', 'availWidth', 'availHeight', 'availLeft', 'availTop', 'colorDepth', 'pixelDepth']) {
    call('screen.' + n, () => screen[n]);
  }
  call('visualViewport', () => [visualViewport.width, visualViewport.height, visualViewport.scale].join(' '));

  // The ratio as the media-query engine sees it: the boundary between the last
  // matching min-resolution and the first that does not.
  for (const n of ['0.5', '1', '1.5', '2', '2.5', '3']) {
    call('mq min-resolution ' + n + 'dppx', () => matchMedia('(min-resolution: ' + n + 'dppx)').matches);
  }
  for (const n of ['96', '192', '288']) {
    call('mq min-resolution ' + n + 'dpi', () => matchMedia('(min-resolution: ' + n + 'dpi)').matches);
  }
  call('mq resolution 1dppx', () => matchMedia('(resolution: 1dppx)').matches);
  call('mq resolution 2dppx', () => matchMedia('(resolution: 2dppx)').matches);
  call('mq device-width == screen.width', () =>
    matchMedia('(device-width: ' + screen.width + 'px)').matches);

  // A laid-out element, in every coordinate system that reports one. `img.x`
  // and `img.y` are the interesting pair: B52 measured them at exactly twice
  // `offsetLeft` / `offsetTop` on a devicePixelRatio-2 Chrome, which is the one
  // place a device pixel leaks into a DOM reading.
  const host = document.createElement('div');
  host.style.cssText = 'position:absolute;left:37px;top:53px;width:101px;height:41px';
  document.documentElement.appendChild(host);
  const img = document.createElement('img');
  img.style.cssText = 'position:absolute;left:11px;top:13px;width:64px;height:32px';
  host.appendChild(img);
  call('host.offsetLeft/Top', () => [host.offsetLeft, host.offsetTop].join(','));
  call('host.getBoundingClientRect', () => {
    const r = host.getBoundingClientRect();
    return [r.left, r.top, r.width, r.height].join(',');
  });
  call('host.offsetWidth/clientWidth', () => [host.offsetWidth, host.clientWidth].join(','));
  call('img.x/y', () => [img.x, img.y].join(','));
  call('img.offsetLeft/Top', () => [img.offsetLeft, img.offsetTop].join(','));
  call('computed host width', () => getComputedStyle(host).width);
  call('documentElement.clientWidth/Height', () =>
    [document.documentElement.clientWidth, document.documentElement.clientHeight].join(','));

  // Canvas: the backing store is CSS pixels unless the page scales it itself,
  // so none of this should move -- which is worth asserting rather than
  // assuming, because it is where a ratio most plausibly leaks.
  const canvas = document.createElement('canvas');
  canvas.style.cssText = 'width:100px;height:50px';
  document.documentElement.appendChild(canvas);
  call('canvas.width/height (default)', () => [canvas.width, canvas.height].join(','));
  call('canvas ctx.getTransform', () => {
    const t = canvas.getContext('2d').getTransform();
    return [t.a, t.b, t.c, t.d, t.e, t.f].join(',');
  });
  call('canvas rect', () => {
    const r = canvas.getBoundingClientRect();
    return [r.width, r.height].join(',');
  });
  call('webgl drawingBuffer', () => {
    const gl = document.createElement('canvas').getContext('webgl');
    return gl ? [gl.drawingBufferWidth, gl.drawingBufferHeight].join(',') : 'no webgl';
  });

  // srcset picks by ratio, so `currentSrc` is a reading that follows from it
  // without any layout involved.
  call('srcset currentSrc', () => {
    const i = document.createElement('img');
    i.srcset = 'one.png 1x, two.png 2x, three.png 3x';
    i.src = 'one.png';
    document.documentElement.appendChild(i);
    const cur = i.currentSrc;
    i.remove();
    return cur ? cur.replace(/^.*\//, '') : String(cur);
  });

  // The multi-screen surface carries its own copy of the ratio; the two have to
  // agree or the page can read the disagreement directly.
  call('screen.isExtended', () => screen.isExtended);
  call('ScreenDetailed on prototype', () => typeof self.ScreenDetailed);

  host.remove();
  canvas.remove();
  return out;
})()
