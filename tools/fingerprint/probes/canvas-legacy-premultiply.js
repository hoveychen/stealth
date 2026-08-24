// Does an eight-bit canvas quantise a *legacy* colour before it premultiplies?
//
// The knife edge is a channel whose float and its rounded byte fall on opposite
// sides of a premultiply boundary. `hsl(30 60% 40%)`'s blue is 40.8: at alpha
// 128/255 the float stores 20 and the byte 41 stores 21, which read back as 40
// and 42. Every row below is a notation whose channels are not byte-valued,
// paired with the `rgb()` form of the byte it rounds to -- if the two arms of a
// pair always agree, the canvas quantised first.
(() => {
  const hex = (d) => [...d].map((b) => b.toString(16).padStart(2, '0')).join('');
  const paint = (space, notation) => {
    const ctx = new OffscreenCanvas(1, 1).getContext('2d', {
      colorSpace: space,
      willReadFrequently: true,
    });
    ctx.fillStyle = notation;
    ctx.fillRect(0, 0, 1, 1);
    return hex(ctx.getImageData(0, 0, 1, 1).data);
  };
  // [float notation, the bytes it answers back]
  const pairs = [
    ['hsl(30 60% 40% / 0.5)', 'rgba(163, 102, 41, 0.5)'],
    ['hsl(30 60% 40% / 0.25)', 'rgba(163, 102, 41, 0.25)'],
    ['hsl(30 60% 40% / 0.75)', 'rgba(163, 102, 41, 0.75)'],
    ['hwb(200 10% 20% / 0.5)', 'rgba(26, 145, 204, 0.5)'],
    ['hwb(200 10% 21% / 0.5)', 'rgba(26, 143, 201, 0.5)'],
    ['hsl(280 70% 30% / 0.5)', 'rgba(94, 23, 130, 0.5)'],
    ['hsl(90 33% 57% / 0.5)', 'rgba(145, 182, 109, 0.5)'],
    ['hsl(210 25% 61% / 0.5)', 'rgba(131, 156, 180, 0.5)'],
    ['hwb(45 15% 35% / 0.5)', 'rgba(166, 134, 38, 0.5)'],
    ['hsl(150 40% 45% / 0.5)', 'rgba(69, 161, 115, 0.5)'],
    ['hwb(300 5% 5% / 0.5)', 'rgba(242, 13, 242, 0.5)'],
    ['hsl(0 0% 50% / 0.5)', 'rgba(128, 128, 128, 0.5)'],
    // The control: a wide notation, which is known to keep its float.
    ['color(display-p3 1 0.25 0.5 / 0.5)', 'rgba(255, 27, 127, 0.5)'],
    ['lab(50 40 30 / 0.5)', 'rgba(187, 88, 70, 0.5)'],
  ];
  const out = {};
  for (const space of ['srgb', 'display-p3']) {
    out[space] = {};
    for (const [float, bytes] of pairs) {
      out[space][float] = `${paint(space, float)} vs ${paint(space, bytes)}`;
    }
  }
  return JSON.stringify(out);
})();
