// The last ambiguities in `getContext`'s second argument, and the WebGL half
// of the same axis.
//
// Two message shapes came back from probe 2 for a bad `colorSpace`, which reads
// as two gates: the dictionary's own enum conversion, and a narrower check the
// canvas applies afterwards. This prints both in full so the split is a reading
// rather than an inference.
//
// And WebGL takes a creation dictionary through the same argument. We answer a
// fixed set there too, so the same bug has a second instance surface.
(() => {
  const ask = (f) => { try { return f(); } catch (e) { return `${e.name}: ${e.message}`; } };

  const full = (settings) => ask(() => JSON.stringify(
    document.createElement('canvas').getContext('2d', settings).getContextAttributes(),
  ));

  const gl = (settings) => ask(() => JSON.stringify(
    document.createElement('canvas').getContext('webgl', settings).getContextAttributes(),
  ));

  return {
    // Whole messages, untruncated, for one value from each suspected gate.
    messages: {
      'canvas colorSpace rec2020': full({ colorSpace: 'rec2020' }),
      'canvas colorSpace nonesuch': full({ colorSpace: 'nonesuch' }),
      'canvas colorType float32': full({ colorType: 'float32' }),
      'imagedata rec2020': ask(() => new ImageData(1, 1, { colorSpace: 'rec2020' }).colorSpace),
      'imagedata nonesuch': ask(() => new ImageData(1, 1, { colorSpace: 'nonesuch' }).colorSpace),
      'imagedata srgb-linear': ask(() => new ImageData(1, 1, { colorSpace: 'srgb-linear' }).colorSpace),
      // getImageData takes the same enum through a different operation, so its
      // prefix names that operation instead.
      'getImageData rec2020': ask(() => new OffscreenCanvas(1, 1)
        .getContext('2d').getImageData(0, 0, 1, 1, { colorSpace: 'rec2020' }).colorSpace),
      'getImageData nonesuch': ask(() => new OffscreenCanvas(1, 1)
        .getContext('2d').getImageData(0, 0, 1, 1, { colorSpace: 'nonesuch' }).colorSpace),
    },
    // Is "undefined" a member of CanvasWillReadFrequently, as the older Blink
    // IDL had it?
    willReadFrequently: {
      '"undefined"': full({ willReadFrequently: 'undefined' }),
      '"auto"': full({ willReadFrequently: 'auto' }),
      'object': full({ willReadFrequently: {} }),
    },
    // WebGLContextAttributes: which members reach getContextAttributes, and
    // what a bad one does.
    webgl: {
      'omitted': gl(undefined),
      'alpha:false': gl({ alpha: false }),
      'depth:false': gl({ depth: false }),
      'stencil:true': gl({ stencil: true }),
      'antialias:false': gl({ antialias: false }),
      'premultipliedAlpha:false': gl({ premultipliedAlpha: false }),
      'preserveDrawingBuffer:true': gl({ preserveDrawingBuffer: true }),
      'failIfMajorPerformanceCaveat:true': gl({ failIfMajorPerformanceCaveat: true }),
      'desynchronized:true': gl({ desynchronized: true }),
      'xrCompatible:true': gl({ xrCompatible: true }),
      'powerPreference:high-performance': gl({ powerPreference: 'high-performance' }),
      'powerPreference:low-power': gl({ powerPreference: 'low-power' }),
      'powerPreference:nonesuch': gl({ powerPreference: 'nonesuch' }),
      'alpha:0': gl({ alpha: 0 }),
      'non-object': gl('nope'),
      'null': gl(null),
      'unknown key': gl({ nonesuch: 1 }),
      // 2D-only members through a WebGL context, and vice versa.
      'colorSpace:display-p3': gl({ colorSpace: 'display-p3' }),
      'willReadFrequently:true': gl({ willReadFrequently: true }),
    },
    webgl2: {
      'omitted': ask(() => JSON.stringify(
        document.createElement('canvas').getContext('webgl2').getContextAttributes(),
      )),
      'alpha:false,xrCompatible:true': ask(() => JSON.stringify(
        document.createElement('canvas')
          .getContext('webgl2', { alpha: false, xrCompatible: true })
          .getContextAttributes(),
      )),
      'offscreen alpha:false': ask(() => JSON.stringify(
        new OffscreenCanvas(2, 2).getContext('webgl2', { alpha: false }).getContextAttributes(),
      )),
      'key order': ask(() => Object.keys(
        document.createElement('canvas').getContext('webgl').getContextAttributes(),
      ).join(',')),
    },
  };
})()
