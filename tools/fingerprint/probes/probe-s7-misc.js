// The seven leftovers of the F7 surface cut: Origin, TextFormat,
// MediaStreamTrackVideoStats, NavigationPrecommitController, Viewport with the
// window.viewport that answers one, and WebGLObject -- which is not just a name
// but the prototype root every WebGL handle is supposed to hang off.
//
// Two of the seven are reachable from script (Origin and TextFormat are
// constructible), one is a live singleton (window.viewport), and the rest are
// illegal constructors whose prototype is the whole surface.
//
//   python3 -m http.server 8777 --bind 0.0.0.0   # in an empty directory
//   node tools/fingerprint/run-probe.mjs chrome probes/probe-s7-misc.js \
//       http://localhost:8777/ --headed
//
// Recorded that way off a headed Chrome 151 in
// results/probes/probe-s7-misc.chrome.json.
(() => {
  const S = (fn) => {
    try {
      const v = fn();
      if (v === undefined) return 'undefined';
      if (v === null) return 'null';
      return typeof v === 'object' ? Object.prototype.toString.call(v) : v;
    } catch (e) { return `${e.name}: ${e.message}`; }
  };
  const flags = (d) => `${d.enumerable ? 'e' : '-'}${d.configurable ? 'c' : '-'}${'writable' in d ? (d.writable ? 'w' : '-') : '-'}`;
  const shapeOf = (o) => {
    const list = [];
    for (const k of Object.getOwnPropertyNames(o)) {
      if (k === 'constructor') continue;
      const d = Object.getOwnPropertyDescriptor(o, k);
      if (d.get || d.set) list.push(`${d.get ? (d.set ? 'accessor' : 'get') : 'set'} ${k}[${flags(d)}]`);
      else if (typeof d.value === 'function') list.push(`${k}/${d.value.length}[${flags(d)}]`);
      else list.push(`${k}=${String(d.value)}[${flags(d)}]`);
    }
    for (const s of Object.getOwnPropertySymbols(o)) {
      const v = o[s];
      list.push(`@@${String(s).replace(/^Symbol\(Symbol\.(.*)\)$/, '$1')}=${typeof v === 'function' ? `fn:${v.name}` : String(v)}`);
    }
    return list.join(',');
  };
  const spy = () => {
    const seen = [];
    return {
      seen,
      p: new Proxy({}, { get(_, k) { seen.push(String(k)); return undefined; }, has() { return true; } }),
    };
  };

  const out = {};
  out.shapes = Object.fromEntries(['Origin', 'TextFormat', 'MediaStreamTrackVideoStats',
    'NavigationPrecommitController', 'Viewport', 'WebGLObject']
    .map((n) => [n, shapeOf(window[n].prototype)]));

  // Origin: constructible, with a static from(). What a bare one is, what it
  // accepts, and what the two comparisons answer.
  out.origin = {
    bare: S(() => `${new Origin().opaque}|${String(new Origin())}`),
    bareJson: S(() => JSON.stringify(new Origin())),
    withUrl: S(() => `${new Origin(location.href).opaque}`),
    withOriginString: S(() => `${new Origin(location.origin).opaque}`),
    withGarbage: S(() => `${new Origin('nope').opaque}`),
    withNumber: S(() => `${new Origin(5).opaque}`),
    withNull: S(() => `${new Origin(null).opaque}`),
    withEmpty: S(() => `${new Origin('').opaque}`),
    fromArity: S(() => Origin.from.length),
    fromBare: S(() => Origin.from()),
    fromUrl: S(() => `${Origin.from(location.href).opaque}`),
    fromOriginString: S(() => `${Origin.from(location.origin).opaque}`),
    fromGarbage: S(() => Origin.from('nope')),
    fromNumber: S(() => Origin.from(5)),
    fromNull: S(() => Origin.from(null)),
    fromEmpty: S(() => Origin.from('')),
    fromBrand: S(() => Object.prototype.toString.call(Origin.from(location.href))),
    fromOrigin: S(() => `${Origin.from(new Origin()).opaque}`),
    // Serialisation: is there a toString / toJSON of its own?
    toStringOfReal: S(() => String(Origin.from(location.href))),
    // The comparisons, on same and different origins.
    sameSelf: S(() => Origin.from(location.href).isSameOrigin(Origin.from(location.href))),
    sameOther: S(() => Origin.from(location.href).isSameOrigin(Origin.from('https://example.com/'))),
    siteSelf: S(() => Origin.from(location.href).isSameSite(Origin.from(location.href))),
    siteOther: S(() => Origin.from(location.href).isSameSite(Origin.from('https://example.com/'))),
    siteSubdomain: S(() => Origin.from('https://a.example.com/').isSameSite(Origin.from('https://b.example.com/'))),
    siteScheme: S(() => Origin.from('https://example.com/').isSameSite(Origin.from('http://example.com/'))),
    samePort: S(() => Origin.from('https://example.com:1/').isSameOrigin(Origin.from('https://example.com:2/'))),
    sitePort: S(() => Origin.from('https://example.com:1/').isSameSite(Origin.from('https://example.com:2/'))),
    opaqueVsOpaque: S(() => new Origin().isSameOrigin(new Origin())),
    opaqueSelf: S(() => { const o = new Origin(); return o.isSameOrigin(o); }),
    sameNoArgs: S(() => Origin.from(location.href).isSameOrigin()),
    sameString: S(() => Origin.from(location.href).isSameOrigin(location.origin)),
    sameNull: S(() => Origin.from(location.href).isSameOrigin(null)),
  };

  // TextFormat: constructible with one optional TextFormatInit.
  out.textFormat = (() => {
    const s = spy();
    const outcome = S(() => new TextFormat(s.p));
    return {
      members: s.seen,
      outcome,
      bare: S(() => {
        const f = new TextFormat();
        return `${f.rangeStart}|${f.rangeEnd}|${f.underlineStyle}|${f.underlineThickness}`;
      }),
      nonDict: S(() => new TextFormat(5)),
      nullDict: S(() => { const f = new TextFormat(null); return `${f.rangeStart}|${f.underlineStyle}`; }),
      filled: S(() => {
        const f = new TextFormat({ rangeStart: 2, rangeEnd: 5, underlineStyle: 'dotted', underlineThickness: 'thick' });
        return `${f.rangeStart}|${f.rangeEnd}|${f.underlineStyle}|${f.underlineThickness}`;
      }),
      negativeRange: S(() => new TextFormat({ rangeStart: -1 }).rangeStart),
      floatRange: S(() => new TextFormat({ rangeStart: 2.7 }).rangeStart),
      hugeRange: S(() => new TextFormat({ rangeStart: 2 ** 33 }).rangeStart),
      nanRange: S(() => new TextFormat({ rangeStart: NaN }).rangeStart),
      stringRange: S(() => new TextFormat({ rangeStart: '9' }).rangeStart),
      styles: Object.fromEntries(['none', 'solid', 'dotted', 'dashed', 'wavy', 'squiggle', '', 'nope']
        .map((v) => [v || '(empty)', S(() => new TextFormat({ underlineStyle: v }).underlineStyle)])),
      thicknesses: Object.fromEntries(['none', 'thin', 'thick', '', 'nope']
        .map((v) => [v || '(empty)', S(() => new TextFormat({ underlineThickness: v }).underlineThickness)])),
      styleNull: S(() => new TextFormat({ underlineStyle: null }).underlineStyle),
      styleUndefined: S(() => new TextFormat({ underlineStyle: undefined }).underlineStyle),
      // Does a TextFormat go into a TextFormatUpdateEvent's sequence?
      inEvent: S(() => new TextFormatUpdateEvent('textformatupdate',
        { textFormats: [new TextFormat()] }).getTextFormats().length),
    };
  })();

  // window.viewport: the live Viewport.
  out.viewport = {
    descriptor: S(() => {
      const d = Object.getOwnPropertyDescriptor(window, 'viewport');
      return `${typeof d.get}|${typeof d.set}|${flags(d)}`;
    }),
    identity: S(() => window.viewport === window.viewport),
    brand: S(() => Object.prototype.toString.call(window.viewport)),
    ownProps: S(() => Object.keys(window.viewport).join(',')),
    json: S(() => JSON.stringify(window.viewport)),
    segments: S(() => JSON.stringify(window.viewport.segments)),
    segmentsLength: S(() => window.viewport.segments.length),
    segmentsIdentity: S(() => window.viewport.segments === window.viewport.segments),
    segmentsFrozen: S(() => Object.isFrozen(window.viewport.segments)),
    firstSegment: S(() => window.viewport.segments[0] &&
      JSON.stringify(window.viewport.segments[0].toJSON ? window.viewport.segments[0].toJSON() : window.viewport.segments[0])),
    firstSegmentBrand: S(() => Object.prototype.toString.call(window.viewport.segments[0])),
  };

  // WebGLObject: which handles actually descend from it, and whether a real one
  // is an instance.
  const gl = S(() => document.createElement('canvas').getContext('webgl'));
  out.webgl = {
    context: gl,
    rootOf: Object.fromEntries(['WebGLBuffer', 'WebGLFramebuffer', 'WebGLProgram', 'WebGLQuery',
      'WebGLRenderbuffer', 'WebGLSampler', 'WebGLShader', 'WebGLSync', 'WebGLTexture',
      'WebGLTransformFeedback', 'WebGLVertexArrayObject', 'WebGLUniformLocation',
      'WebGLActiveInfo', 'WebGLShaderPrecisionFormat']
      .map((n) => [n, S(() => {
        const c = window[n];
        if (!c) return 'absent';
        const parent = Object.getPrototypeOf(c.prototype);
        return parent === Object.prototype ? 'Object' : parent.constructor.name;
      })])),
    ctorParents: Object.fromEntries(['WebGLBuffer', 'WebGLTexture', 'WebGLUniformLocation']
      .map((n) => [n, S(() => Object.getPrototypeOf(window[n]) === WebGLObject ? 'WebGLObject' : 'Function')])),
    instance: S(() => {
      const context = document.createElement('canvas').getContext('webgl');
      if (!context) return 'no context';
      const buffer = context.createBuffer();
      return `${buffer instanceof WebGLObject}|${buffer instanceof WebGLBuffer}|` +
        `${Object.prototype.toString.call(buffer)}`;
    }),
    uniformInstance: S(() => {
      const context = document.createElement('canvas').getContext('webgl');
      if (!context) return 'no context';
      const program = context.createProgram();
      return `${program instanceof WebGLObject}`;
    }),
  };

  // The two illegal singletons whose prototypes are all a page sees, read off
  // the prototype the way a detector would.
  out.unreachable = {};
  for (const n of ['MediaStreamTrackVideoStats', 'NavigationPrecommitController', 'Viewport']) {
    const proto = window[n].prototype;
    const per = {};
    for (const k of Object.getOwnPropertyNames(proto)) {
      if (k === 'constructor') continue;
      per[k] = S(() => {
        const d = Object.getOwnPropertyDescriptor(proto, k);
        return d.get ? d.get.call(proto) : d.value.call(proto);
      });
    }
    out.unreachable[n] = per;
  }
  // Is a video track's stats object reachable at all without a device?
  out.trackStats = {
    hasStats: S(() => 'stats' in MediaStreamTrack.prototype),
    statsArity: S(() => MediaStreamTrack.prototype.stats.length),
    onProto: S(() => MediaStreamTrack.prototype.stats.call(MediaStreamTrack.prototype)),
  };

  return { href: location.href, isSecureContext: window.isSecureContext, out };
})()
