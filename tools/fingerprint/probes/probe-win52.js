// Batch 18 / P1: the whole WebXR family -- the 34 XR* window globals plus the
// navigator.xr entry point that already exists in this engine.
//
// WebXR is [SecureContext], so this must run on a secure origin
// (http://localhost counts). About:blank gives "XRSession is not defined".
(async () => {
  const NAMES = [
    'XRAnchor', 'XRAnchorSet', 'XRBoundedReferenceSpace', 'XRCPUDepthInformation',
    'XRCamera', 'XRDOMOverlayState', 'XRDepthInformation', 'XRFrame',
    'XRHitTestResult', 'XRHitTestSource', 'XRInputSource', 'XRInputSourceArray',
    'XRInputSourceEvent', 'XRInputSourcesChangeEvent', 'XRLayer', 'XRLightEstimate',
    'XRLightProbe', 'XRPose', 'XRRay', 'XRReferenceSpace', 'XRReferenceSpaceEvent',
    'XRRenderState', 'XRRigidTransform', 'XRSession', 'XRSessionEvent', 'XRSpace',
    'XRTransientInputHitTestResult', 'XRTransientInputHitTestSource', 'XRView',
    'XRViewerPose', 'XRViewport', 'XRWebGLBinding', 'XRWebGLDepthInformation',
    'XRWebGLLayer', 'XRSystem',
  ];

  const s = (f) => { try { const v = f(); return v === undefined ? 'undefined' : String(v); } catch (e) { return `${e.name}: ${e.message}`; } };
  const flags = (d) => `${d.enumerable ? 'e' : '-'}${d.configurable ? 'c' : '-'}${'writable' in d ? (d.writable ? 'w' : '-') : '-'}`;
  const shapeOf = (o) => {
    const out = [];
    for (const k of Object.getOwnPropertyNames(o)) {
      if (k === 'constructor') continue;
      const d = Object.getOwnPropertyDescriptor(o, k);
      if (d.get || d.set) out.push(`${d.get ? (d.set ? 'accessor' : 'get') : 'set'} ${k}[${flags(d)}]`);
      else if (typeof d.value === 'function') out.push(`${k}/${d.value.length}[${flags(d)}]`);
      else out.push(`${k}=${String(d.value)}[${flags(d)}]`);
    }
    for (const sym of Object.getOwnPropertySymbols(o)) {
      const v = o[sym];
      out.push(`@@${String(sym).replace(/^Symbol\(Symbol\.(.*)\)$/, '$1')}=${typeof v === 'function' ? `fn:${v.name}` : String(v)}`);
    }
    return out.join(',');
  };

  const out = { secureContext: String(window.isSecureContext), origin: String(location.origin) };

  out.interfaces = {};
  for (const name of NAMES) {
    const rec = {};
    const d = Object.getOwnPropertyDescriptor(window, name);
    if (!d) { rec.missing = true; out.interfaces[name] = rec; continue; }
    rec.windowFlags = flags(d);
    const C = d.value;
    rec.typeofValue = typeof C;
    rec.arity = s(() => C.length);
    rec.ctorName = s(() => C.name);
    rec.ctorString = s(() => String(C).slice(0, 60));
    rec.protoOfCtor = s(() => Object.getPrototypeOf(C).name ?? String(Object.getPrototypeOf(C)));
    rec.statics = s(() => Object.getOwnPropertyNames(C).filter((k) => !['length', 'name', 'prototype'].includes(k)).join(','));
    rec.staticSyms = s(() => Object.getOwnPropertySymbols(C).map(String).join(','));
    rec.protoChain = s(() => {
      const chain = [];
      let p = Object.getPrototypeOf(C.prototype);
      while (p && chain.length < 6) { chain.push(p.constructor ? p.constructor.name : '?'); p = Object.getPrototypeOf(p); }
      return chain.join('<-');
    });
    rec.toStringTag = s(() => C.prototype[Symbol.toStringTag]);
    rec.protoOwn = s(() => shapeOf(C.prototype));
    rec.newNoArgs = s(() => { const v = new C(); return `constructed ${Object.prototype.toString.call(v)}`; });
    rec.callNoNew = s(() => { C(); return 'called'; });
    out.interfaces[name] = rec;
  }

  // navigator.xr behaviour: what the entry point answers without a device.
  const xr = navigator.xr;
  out.xr = {
    present: String(!!xr),
    brand: Object.prototype.toString.call(xr),
    protoIsXRSystem: s(() => Object.getPrototypeOf(xr) === window.XRSystem.prototype),
    isSessionSupported: {},
    requestSession: {},
  };
  for (const mode of ['inline', 'immersive-vr', 'immersive-ar', 'nope', '']) {
    out.xr.isSessionSupported[mode] = await Promise.resolve()
      .then(() => xr.isSessionSupported(mode))
      .then((v) => `resolved ${String(v)}`, (e) => `${e.name}: ${e.message}`);
  }
  out.xr.isSessionSupportedNoArg = await Promise.resolve()
    .then(() => xr.isSessionSupported())
    .then((v) => `resolved ${String(v)}`, (e) => `${e.name}: ${e.message}`);
  for (const mode of ['inline', 'immersive-vr', 'immersive-ar', 'nope']) {
    out.xr.requestSession[mode] = await Promise.resolve()
      .then(() => xr.requestSession(mode))
      .then((v) => `resolved ${Object.prototype.toString.call(v)}`, (e) => `${e.name}: ${e.message}`);
  }
  out.xr.requestSessionNoArg = await Promise.resolve()
    .then(() => xr.requestSession())
    .then(() => 'resolved', (e) => `${e.name}: ${e.message}`);
  out.xr.ondevicechange = s(() => String(xr.ondevicechange));

  // The two constructible XR types, exercised for real: XRRigidTransform and
  // XRRay. Everything else in the family is [Exposed] only.
  out.rigidTransform = (() => {
    const r = {};
    r.noArgs = s(() => { const t = new XRRigidTransform(); return `${t.position.x},${t.position.y},${t.position.z},${t.position.w}|${t.orientation.x},${t.orientation.y},${t.orientation.z},${t.orientation.w}`; });
    r.matrixNoArgs = s(() => Array.from(new XRRigidTransform().matrix).join(','));
    r.matrixBrand = s(() => Object.prototype.toString.call(new XRRigidTransform().matrix));
    r.matrixStable = s(() => { const t = new XRRigidTransform(); return t.matrix === t.matrix; });
    r.positionBrand = s(() => Object.prototype.toString.call(new XRRigidTransform().position));
    r.positionStable = s(() => { const t = new XRRigidTransform(); return t.position === t.position; });
    r.withPosition = s(() => { const t = new XRRigidTransform({ x: 1, y: 2, z: 3 }); return `${t.position.x},${t.position.y},${t.position.z},${t.position.w}`; });
    r.withPositionW = s(() => { const t = new XRRigidTransform({ x: 1, y: 2, z: 3, w: 2 }); return `${t.position.w}`; });
    r.withOrientation = s(() => { const t = new XRRigidTransform({}, { x: 0, y: 0, z: 1, w: 1 }); return `${t.orientation.x},${t.orientation.y},${t.orientation.z},${t.orientation.w}`; });
    r.orientationNormalized = s(() => { const t = new XRRigidTransform({}, { x: 3, y: 0, z: 0, w: 4 }); return `${t.orientation.x},${t.orientation.y},${t.orientation.z},${t.orientation.w}`; });
    r.zeroOrientation = s(() => { const t = new XRRigidTransform({}, { x: 0, y: 0, z: 0, w: 0 }); return `${t.orientation.x},${t.orientation.y},${t.orientation.z},${t.orientation.w}`; });
    r.translationMatrix = s(() => Array.from(new XRRigidTransform({ x: 1, y: 2, z: 3 }).matrix).join(','));
    r.rotationMatrix = s(() => Array.from(new XRRigidTransform({}, { x: 0, y: 0, z: 1, w: 0 }).matrix).map((n) => Math.round(n * 1e6) / 1e6).join(','));
    r.inverse = s(() => { const t = new XRRigidTransform({ x: 1, y: 2, z: 3 }); const i = t.inverse; return `${i.position.x},${i.position.y},${i.position.z}`; });
    r.inverseStable = s(() => { const t = new XRRigidTransform(); return t.inverse === t.inverse; });
    r.inverseOfInverse = s(() => { const t = new XRRigidTransform({ x: 1, y: 2, z: 3 }); return t.inverse.inverse === t; });
    r.badPosition = s(() => new XRRigidTransform('x'));
    r.nonFinite = s(() => new XRRigidTransform({ x: Infinity }));
    r.positionWNot1 = s(() => new XRRigidTransform({ x: 0, y: 0, z: 0, w: 0 }));
    return r;
  })();

  out.ray = (() => {
    const r = {};
    r.noArgs = s(() => { const y = new XRRay(); return `${y.origin.x},${y.origin.y},${y.origin.z},${y.origin.w}|${y.direction.x},${y.direction.y},${y.direction.z},${y.direction.w}`; });
    r.matrixNoArgs = s(() => Array.from(new XRRay().matrix).map((n) => Math.round(n * 1e6) / 1e6).join(','));
    r.matrixBrand = s(() => Object.prototype.toString.call(new XRRay().matrix));
    r.originBrand = s(() => Object.prototype.toString.call(new XRRay().origin));
    r.originStable = s(() => { const y = new XRRay(); return y.origin === y.origin; });
    r.matrixStable = s(() => { const y = new XRRay(); return y.matrix === y.matrix; });
    r.withOrigin = s(() => { const y = new XRRay({ x: 1, y: 2, z: 3 }); return `${y.origin.x},${y.origin.y},${y.origin.z},${y.origin.w}`; });
    r.withDirection = s(() => { const y = new XRRay({}, { x: 0, y: 1, z: 0 }); return `${y.direction.x},${y.direction.y},${y.direction.z},${y.direction.w}`; });
    r.directionNormalized = s(() => { const y = new XRRay({}, { x: 0, y: 3, z: 4 }); return `${y.direction.x},${y.direction.y},${y.direction.z}`; });
    r.zeroDirection = s(() => new XRRay({}, { x: 0, y: 0, z: 0 }));
    r.originW = s(() => new XRRay({ x: 0, y: 0, z: 0, w: 0 }));
    r.directionW = s(() => { const y = new XRRay({}, { x: 0, y: 0, z: -1, w: 1 }); return `${y.direction.w}`; });
    r.fromTransform = s(() => { const y = new XRRay(new XRRigidTransform({ x: 1, y: 2, z: 3 })); return `${y.origin.x},${y.origin.y},${y.origin.z}|${y.direction.x},${y.direction.y},${y.direction.z}`; });
    r.fromTransformExtraArg = s(() => new XRRay(new XRRigidTransform(), { x: 0, y: 1, z: 0 }));
    r.rotatedMatrix = s(() => Array.from(new XRRay({}, { x: 1, y: 0, z: 0 }).matrix).map((n) => Math.round(n * 1e6) / 1e6).join(','));
    return r;
  })();

  // XRWebGLLayer's two statics, and whether the constructor is reachable
  // without a session.
  out.webglLayer = {
    statics: s(() => Object.getOwnPropertyNames(XRWebGLLayer).filter((k) => !['length', 'name', 'prototype'].includes(k)).join(',')),
    defaultFramebufferScaleFactor: s(() => XRWebGLLayer.getNativeFramebufferScaleFactor === undefined ? 'no fn' : 'has fn'),
    nativeScaleNoArg: s(() => XRWebGLLayer.getNativeFramebufferScaleFactor()),
    nativeScaleNull: s(() => XRWebGLLayer.getNativeFramebufferScaleFactor(null)),
    nativeScaleBad: s(() => XRWebGLLayer.getNativeFramebufferScaleFactor({})),
  };

  out.webglBinding = {
    newNoArgs: s(() => new XRWebGLBinding()),
    newWithNulls: s(() => new XRWebGLBinding(null, null)),
    newWithGl: s(() => {
      const c = document.createElement('canvas');
      return String(new XRWebGLBinding(null, c.getContext('webgl')));
    }),
  };

  // The event subclasses: are they constructible from script, and what do
  // their required dictionary members reject with?
  out.events = {};
  for (const [name, dict] of [
    ['XRSessionEvent', { session: null }],
    ['XRInputSourceEvent', { frame: null, inputSource: null }],
    ['XRInputSourcesChangeEvent', { session: null, added: [], removed: [] }],
    ['XRReferenceSpaceEvent', { referenceSpace: null }],
  ]) {
    const C = window[name];
    if (!C) { out.events[name] = 'missing'; continue; }
    out.events[name] = {
      noArgs: s(() => new C()),
      typeOnly: s(() => new C('x')),
      withNullDict: s(() => new C('x', dict)),
      emptyDict: s(() => new C('x', {})),
    };
  }

  // The XRSystem prototype and the XR-related bits hanging off other
  // interfaces that this family needs to plug into.
  out.neighbours = {
    navigatorXrDescriptor: s(() => flags(Object.getOwnPropertyDescriptor(Navigator.prototype, 'xr'))),
    windowOnbeforexrselect: s(() => 'onbeforexrselect' in window),
    htmlElementOnbeforexrselect: s(() => 'onbeforexrselect' in HTMLElement.prototype),
    webglMakeXRCompatible: s(() => typeof WebGLRenderingContext.prototype.makeXRCompatible),
    webgl2MakeXRCompatible: s(() => typeof WebGL2RenderingContext.prototype.makeXRCompatible),
    webglAttrXrCompatible: s(() => String(document.createElement('canvas').getContext('webgl').getContextAttributes().xrCompatible)),
    makeXRCompatibleResult: await Promise.resolve()
      .then(() => document.createElement('canvas').getContext('webgl').makeXRCompatible())
      .then(() => 'resolved', (e) => `${e.name}: ${e.message}`),
  };

  // How many XR names window actually carries, so the count is on the record.
  out.windowXRKeys = Object.getOwnPropertyNames(window).filter((k) => k.startsWith('XR')).sort().join(',');

  return out;
})()
