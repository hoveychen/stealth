// The two fields canvas-context-settings.js left ambiguous.
//
// `willReadFrequently` reads as a boolean out of getContextAttributes, but the
// TypeError it raises names `CanvasWillReadFrequently` -- an *enum*, so the JS
// boolean `true` only works because it stringifies to the member "true". This
// pins which strings the enum has and what boolean each maps back to.
//
// And `colorSpace: 'rec2020'` fails with a different message shape than
// 'nonesuch' does, which says it clears the dictionary conversion and is
// refused by a second gate. This measures that gate's membership directly.
(() => {
  const ask = (f) => { try { return f(); } catch (e) { return `throw:${e.name}: ${e.message}`; } };

  const attrs = (settings) => ask(() => JSON.stringify(
    document.createElement('canvas').getContext('2d', settings).getContextAttributes(),
  ));

  const oneField = (field, values) => {
    const out = {};
    for (const v of values) {
      out[typeof v === 'string' ? `"${v}"` : String(v)] = attrs({ [field]: v });
    }
    return out;
  };

  return {
    willReadFrequently: oneField('willReadFrequently', [
      true, false, 'true', 'false', 'auto', 'TRUE', '', 0, 1, null, undefined,
    ]),
    // Every colour space name the platform knows from other IDL, to see which
    // clear the dictionary and which the canvas itself then refuses.
    colorSpace: oneField('colorSpace', [
      'srgb', 'display-p3', 'rec2020', 'srgb-linear', 'a98-rgb',
      'prophoto-rgb', 'rec2100-hlg', 'rec2100-pq', 'xyz', 'xyz-d50', 'xyz-d65',
      'hsl', 'hwb', 'lab', 'oklab', 'lch', 'oklch',
    ]),
    colorType: oneField('colorType', ['unorm8', 'float16', 'uint8', 'float32']),
    // Same names through ImageData, whose PredefinedColorSpace is the one the
    // canvas dictionary shares -- so a name valid here and refused above is
    // proof of the second gate rather than of a narrower enum.
    imageDataColorSpace: (() => {
      const out = {};
      for (const cs of ['srgb', 'display-p3', 'rec2020', 'srgb-linear', 'nonesuch']) {
        out[cs] = ask(() => new ImageData(1, 1, { colorSpace: cs }).colorSpace);
      }
      return out;
    })(),
    // Does an unknown context type still convert the dictionary?
    unknownType: {
      'nonesuch + bad colorSpace': ask(() => String(
        document.createElement('canvas').getContext('nonesuch', { colorSpace: 'bad' }),
      )),
      'webgl + bad colorSpace': ask(() => String(
        document.createElement('canvas').getContext('webgl', { colorSpace: 'bad' }) !== null,
      )),
      '2d after webgl, bad colorSpace': ask(() => {
        const c = document.createElement('canvas');
        c.getContext('webgl');
        return String(c.getContext('2d', { colorSpace: 'bad' }));
      }),
    },
    // alpha:false is the one attribute with a pixel consequence: an opaque
    // canvas starts black rather than transparent.
    opaque: {
      'alpha:false initial pixel': ask(() => {
        const ctx = new OffscreenCanvas(1, 1).getContext('2d', { alpha: false });
        return [...ctx.getImageData(0, 0, 1, 1).data].join(',');
      }),
      'alpha:true initial pixel': ask(() => {
        const ctx = new OffscreenCanvas(1, 1).getContext('2d', { alpha: true });
        return [...ctx.getImageData(0, 0, 1, 1).data].join(',');
      }),
      'alpha:false semi-transparent fill': ask(() => {
        const ctx = new OffscreenCanvas(1, 1).getContext('2d', { alpha: false });
        ctx.fillStyle = 'rgba(255,0,0,0.5)';
        ctx.fillRect(0, 0, 1, 1);
        return [...ctx.getImageData(0, 0, 1, 1).data].join(',');
      }),
      'alpha:false clearRect': ask(() => {
        const ctx = new OffscreenCanvas(1, 1).getContext('2d', { alpha: false });
        ctx.fillStyle = '#ff0000';
        ctx.fillRect(0, 0, 1, 1);
        ctx.clearRect(0, 0, 1, 1);
        return [...ctx.getImageData(0, 0, 1, 1).data].join(',');
      }),
    },
  };
})()
