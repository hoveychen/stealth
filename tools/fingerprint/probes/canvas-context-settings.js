// What `getContext('2d', settings)` does with its second argument: which
// fields survive into `getContextAttributes()`, which values are rejected and
// how, and what a second call with different settings answers.
//
// The Turnstile widget builds four 2D contexts and passes
// `{colorSpace, colorType, willReadFrequently: true}` to every one of them
// (results/ibt2-oracle.json). We drop the argument entirely, so all four come
// out as the default srgb/unorm8/willReadFrequently:false context. This probe
// pins the whole dictionary's behaviour rather than only the two fields the
// widget varies, so the parser can be written from readings instead of from
// the WebIDL.
(() => {
  const ask = (f) => { try { return f(); } catch (e) { return `throw:${e.name}: ${e.message}`; } };

  // The arity matters: an omitted second argument and an explicit `undefined`
  // are different calls, and a map value of `undefined` cannot tell them apart.
  const OMITTED = Symbol('omitted');

  // A fresh canvas per call: a canvas hands back its first context forever, so
  // reusing one would measure caching rather than parsing.
  const attrs = (settings, kind) => ask(() => {
    const c = kind === 'offscreen'
      ? new OffscreenCanvas(2, 2)
      : document.createElement('canvas');
    const r = settings === OMITTED ? c.getContext('2d') : c.getContext('2d', settings);
    return JSON.stringify(r.getContextAttributes());
  });

  const settings = {
    'omitted': OMITTED,
    'empty': {},
    'null': null,
    'undefined-literal': undefined,
    'string': 'srgb',
    'number': 42,
    'true': true,
    'false': false,
    'array': [],
    'alpha:false': { alpha: false },
    'alpha:0': { alpha: 0 },
    'alpha:"false"': { alpha: 'false' },
    'willReadFrequently:true': { willReadFrequently: true },
    'willReadFrequently:1': { willReadFrequently: 1 },
    'willReadFrequently:"no"': { willReadFrequently: 'no' },
    'desynchronized:true': { desynchronized: true },
    'colorSpace:display-p3': { colorSpace: 'display-p3' },
    'colorSpace:srgb': { colorSpace: 'srgb' },
    'colorSpace:rec2020': { colorSpace: 'rec2020' },
    'colorSpace:DISPLAY-P3': { colorSpace: 'DISPLAY-P3' },
    'colorSpace:nonesuch': { colorSpace: 'nonesuch' },
    'colorSpace:null': { colorSpace: null },
    'colorSpace:undefined': { colorSpace: undefined },
    'colorSpace:42': { colorSpace: 42 },
    'colorType:float16': { colorType: 'float16' },
    'colorType:unorm8': { colorType: 'unorm8' },
    'colorType:nonesuch': { colorType: 'nonesuch' },
    'toneMapping:{}': { toneMapping: {} },
    'toneMapping:{mode:extended}': { toneMapping: { mode: 'extended' } },
    'toneMapping:{mode:nonesuch}': { toneMapping: { mode: 'nonesuch' } },
    'unknown-key': { nonesuch: 1 },
    'widget': { colorSpace: 'display-p3', colorType: 'float16', willReadFrequently: true },
    'all': {
      alpha: false,
      colorSpace: 'display-p3',
      colorType: 'float16',
      desynchronized: true,
      willReadFrequently: true,
    },
    'getter-throws': { get colorSpace() { throw new TypeError('boom'); } },
  };

  const element = {};
  const offscreen = {};
  for (const [name, value] of Object.entries(settings)) {
    element[name] = attrs(value, 'element');
    offscreen[name] = attrs(value, 'offscreen');
  }

  // A canvas answers its first context forever. Does the second call's
  // dictionary reach the attributes, and does a mismatched one answer null?
  const caching = {
    'element: p3 then srgb': ask(() => {
      const c = document.createElement('canvas');
      const first = c.getContext('2d', { colorSpace: 'display-p3', willReadFrequently: true });
      const second = c.getContext('2d', { colorSpace: 'srgb', willReadFrequently: false });
      return `same=${first === second} ${JSON.stringify(second.getContextAttributes())}`;
    }),
    'element: srgb then p3': ask(() => {
      const c = document.createElement('canvas');
      const first = c.getContext('2d');
      const second = c.getContext('2d', { colorSpace: 'display-p3' });
      return `same=${first === second} ${JSON.stringify(second.getContextAttributes())}`;
    }),
    'offscreen: p3 then srgb': ask(() => {
      const c = new OffscreenCanvas(2, 2);
      const first = c.getContext('2d', { colorSpace: 'display-p3', willReadFrequently: true });
      const second = c.getContext('2d', { colorSpace: 'srgb' });
      return `same=${first === second} ${JSON.stringify(second.getContextAttributes())}`;
    }),
    'element: width reset keeps attributes': ask(() => {
      const c = document.createElement('canvas');
      const ctx = c.getContext('2d', { colorSpace: 'display-p3', willReadFrequently: true });
      c.width = 3;
      return JSON.stringify(ctx.getContextAttributes());
    }),
    'element: bad settings on second call': ask(() => {
      const c = document.createElement('canvas');
      c.getContext('2d');
      return JSON.stringify(c.getContext('2d', { colorSpace: 'nonesuch' }));
    }),
  };

  // The other context types take the same second argument. What do they keep?
  const others = {
    'webgl {alpha:false}': ask(() => JSON.stringify(
      document.createElement('canvas').getContext('webgl', { alpha: false }),
    ) && JSON.stringify(
      document.createElement('canvas').getContext('webgl', { alpha: false }).getContextAttributes(),
    )),
    'webgl2 {antialias:false,depth:false}': ask(() => JSON.stringify(
      document.createElement('canvas')
        .getContext('webgl2', { antialias: false, depth: false })
        .getContextAttributes(),
    )),
    'bitmaprenderer {alpha:false}': ask(() => {
      const ctx = document.createElement('canvas').getContext('bitmaprenderer', { alpha: false });
      return typeof ctx.getContextAttributes;
    }),
    '2d prototype has getContextAttributes': ask(() =>
      Object.getOwnPropertyNames(CanvasRenderingContext2D.prototype).includes('getContextAttributes')),
  };

  // The keys and their order, since JSON.stringify above already fixes the
  // order but a script could enumerate the object instead.
  const shape = ask(() => {
    const a = document.createElement('canvas').getContext('2d').getContextAttributes();
    return Object.keys(a).join(',');
  });

  return { element, offscreen, caching, others, shape };
})()
