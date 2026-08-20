(async () => {
  // Batch 15 behaviour: what the constructible members of the misc-49 actually
  // do, plus where the non-constructible ones' instances come from in a page.
  const out = {};
  const S = (fn) => { try { const v = fn(); return typeof v === 'object' && v !== null ? JSON.stringify(v) : String(v); } catch (e) { return `${e.name}: ${e.message}`; } };
  const T = (p, ms = 1200) => Promise.race([
    Promise.resolve(p).then((v) => ({ settled: 'resolved', value: String(v), brand: v && Object.prototype.toString.call(v) }), (e) => ({ settled: 'rejected', err: `${e.name}: ${e.message}` })),
    new Promise((r) => setTimeout(() => r({ settled: 'pending' }), ms)),
  ]);
  const brand = (v) => { try { return `${Object.prototype.toString.call(v)} ctor=${v && v.constructor && v.constructor.name}`; } catch (e) { return `ERR ${e.name}`; } };

  // ---- Event subclasses: defaults with no init, then a filled init ---------
  out.events = {};
  const ev = (name, args, fields) => {
    try {
      const e = new window[name](...args);
      const r = { type: e.type, bubbles: e.bubbles, cancelable: e.cancelable, composed: e.composed, isTrusted: e.isTrusted, own: Object.getOwnPropertyNames(e).join(','), brand: Object.prototype.toString.call(e) };
      for (const f of fields) r[f] = S(() => { const v = e[f]; return v && typeof v === 'object' ? Object.prototype.toString.call(v) : v; });
      return r;
    } catch (e) { return `${e.name}: ${e.message}`; }
  };
  out.events.AnimationPlaybackEvent_bare = ev('AnimationPlaybackEvent', ['x'], ['currentTime', 'timelineTime']);
  out.events.AnimationPlaybackEvent_init = ev('AnimationPlaybackEvent', ['x', { currentTime: 5, timelineTime: 7, bubbles: true }], ['currentTime', 'timelineTime']);
  out.events.BeforeInstallPromptEvent_bare = ev('BeforeInstallPromptEvent', ['x'], ['platforms', 'userChoice']);
  out.events.BeforeInstallPromptEvent_prompt = await T((() => { try { return new BeforeInstallPromptEvent('x').prompt(); } catch (e) { return Promise.reject(e); } })());
  out.events.BlobEvent_missingData = S(() => new BlobEvent('x', {}));
  out.events.BlobEvent_nonDict = S(() => new BlobEvent('x', 5));
  out.events.BlobEvent_init = ev('BlobEvent', ['x', { data: new Blob(['ab']), timecode: 3 }], ['data', 'timecode']);
  out.events.ClipboardEvent_bare = ev('ClipboardEvent', ['x'], ['clipboardData']);
  out.events.ClipboardEvent_init = ev('ClipboardEvent', ['x', { clipboardData: null }], ['clipboardData']);
  out.events.ContentVisibility_bare = ev('ContentVisibilityAutoStateChangeEvent', ['x'], ['skipped']);
  out.events.ContentVisibility_init = ev('ContentVisibilityAutoStateChangeEvent', ['x', { skipped: true }], ['skipped']);
  out.events.PictureInPictureEvent_missing = S(() => new PictureInPictureEvent('x'));
  out.events.PictureInPictureEvent_null = S(() => new PictureInPictureEvent('x', { pictureInPictureWindow: null }));
  out.events.SecurityPolicyViolationEvent_bare = ev('SecurityPolicyViolationEvent', ['x'], ['documentURI', 'referrer', 'blockedURI', 'violatedDirective', 'effectiveDirective', 'originalPolicy', 'disposition', 'sourceFile', 'statusCode', 'lineNumber', 'columnNumber', 'sample']);
  out.events.SecurityPolicyViolationEvent_init = ev('SecurityPolicyViolationEvent', ['securitypolicyviolation', { documentURI: 'a', blockedURI: 'b', disposition: 'report', statusCode: 200, lineNumber: 4, columnNumber: 9, sample: 's', originalPolicy: 'p', violatedDirective: 'v', effectiveDirective: 'ed', sourceFile: 'f', referrer: 'r' }], ['documentURI', 'blockedURI', 'disposition', 'statusCode', 'lineNumber', 'columnNumber', 'sample', 'violatedDirective', 'effectiveDirective', 'sourceFile', 'referrer', 'originalPolicy']);
  out.events.SecurityPolicyViolationEvent_badDisposition = S(() => new SecurityPolicyViolationEvent('x', { disposition: 'nope' }));
  out.events.TrackEvent_bare = ev('TrackEvent', ['x'], ['track']);
  out.events.TrackEvent_init = ev('TrackEvent', ['x', { track: null }], ['track']);
  out.events.WebGLContextEvent_bare = ev('WebGLContextEvent', ['webglcontextlost'], ['statusMessage']);
  out.events.WebGLContextEvent_init = ev('WebGLContextEvent', ['x', { statusMessage: 'lost' }], ['statusMessage']);
  out.events.VirtualKeyboard_bare = ev('VirtualKeyboardGeometryChangeEvent', ['x'], []);
  out.events.WindowControlsOverlay_missing = S(() => new WindowControlsOverlayGeometryChangeEvent('x'));
  out.events.WindowControlsOverlay_init = ev('WindowControlsOverlayGeometryChangeEvent', ['x', { titlebarAreaRect: new DOMRect(1, 2, 3, 4), visible: true }], ['titlebarAreaRect', 'visible']);
  out.events.NavigateEvent_missing = S(() => new NavigateEvent('navigate'));
  out.events.NavigateEvent_init = ev('NavigateEvent', ['navigate', { destination: null, signal: new AbortController().signal }], ['navigationType', 'destination', 'canIntercept', 'userInitiated', 'hashChange', 'signal', 'formData', 'downloadRequest', 'info', 'sourceElement', 'hasUAVisualTransition']);
  out.events.MutationEvent = typeof MutationEvent;

  // ---- Geometry / collections --------------------------------------------
  out.geom = {};
  out.geom.quadBare = S(() => { const q = new DOMQuad(); return { p1: [q.p1.x, q.p1.y, q.p1.z, q.p1.w], p4: [q.p4.x, q.p4.y], p1Brand: Object.prototype.toString.call(q.p1), bounds: JSON.stringify(q.getBounds()), json: JSON.stringify(q.toJSON()) }; });
  out.geom.quadFromRect = S(() => { const q = DOMQuad.fromRect({ x: 1, y: 2, width: 3, height: 4 }); return { p1: [q.p1.x, q.p1.y], p2: [q.p2.x, q.p2.y], p3: [q.p3.x, q.p3.y], p4: [q.p4.x, q.p4.y], bounds: JSON.stringify(q.getBounds()) }; });
  out.geom.quadFromQuad = S(() => { const q = DOMQuad.fromQuad({ p1: { x: 5, y: 6 } }); return { p1: [q.p1.x, q.p1.y], p2: [q.p2.x, q.p2.y] }; });
  out.geom.quadFromPoints = S(() => { const q = new DOMQuad({ x: 1, y: 1 }, { x: 4, y: 1 }, { x: 4, y: 5 }, { x: 1, y: 5 }); return { bounds: JSON.stringify(q.getBounds()), p3: [q.p3.x, q.p3.y] }; });
  out.geom.quadP1Writable = S(() => { const q = new DOMQuad(); q.p1.x = 9; return q.p1.x; });
  out.geom.path2dBare = S(() => { const p = new Path2D(); p.moveTo(0, 0); p.lineTo(5, 5); p.rect(0, 0, 2, 2); p.closePath(); return 'ok'; });
  out.geom.path2dFromPath = S(() => { const a = new Path2D(); const b = new Path2D(a); return brand(b); });
  out.geom.path2dFromSvg = S(() => brand(new Path2D('M0 0 L10 10')));
  out.geom.path2dAddPathNonPath = S(() => new Path2D().addPath({}));
  out.geom.path2dUsedByCanvas = S(() => { const c = document.createElement('canvas'); const ctx = c.getContext('2d'); const p = new Path2D(); p.rect(0, 0, 4, 4); ctx.fillStyle = '#f00'; ctx.fill(p); return String(ctx.getImageData(1, 1, 1, 1).data.join(',')); });
  out.geom.clientRects = S(() => brand(document.body.getClientRects()));
  out.geom.clientRectsLen = S(() => { const r = document.body.getClientRects(); return { length: r.length, zero: r[0] && Object.prototype.toString.call(r[0]), item: brand(r.item(0)), itemOob: String(r.item(9)), spread: Array.from(r).length }; });
  out.geom.touchBare = S(() => new Touch({}));
  out.geom.touchMinimal = S(() => { const t = new Touch({ identifier: 3, target: document.body }); return { identifier: t.identifier, target: brand(t.target), screenX: t.screenX, clientY: t.clientY, radiusX: t.radiusX, force: t.force, rotationAngle: t.rotationAngle, pageX: t.pageX }; });
  out.geom.touchNoTarget = S(() => new Touch({ identifier: 1 }));
  out.geom.touchFull = S(() => { const t = new Touch({ identifier: 1, target: document.body, clientX: 10, clientY: 20, screenX: 30, screenY: 40, pageX: 50, pageY: 60, radiusX: 2, radiusY: 3, rotationAngle: 45, force: 0.5 }); return [t.clientX, t.pageY, t.radiusY, t.rotationAngle, t.force].join('|'); });
  out.geom.touchList = S(() => { try { return brand(document.createTouchList(new Touch({ identifier: 1, target: document.body }))); } catch (e) { return `no createTouchList: ${e.name}`; } });
  out.geom.timeRanges = S(() => { const v = document.createElement('video'); return { buffered: brand(v.buffered), len: v.buffered.length, played: brand(v.played), seekable: brand(v.seekable), startOob: S(() => v.buffered.start(0)), endOob: S(() => v.buffered.end(0)) }; });
  out.geom.deviceMotionCtors = S(() => ({ accel: typeof DeviceMotionEventAcceleration, rot: typeof DeviceMotionEventRotationRate, dme: typeof DeviceMotionEvent, dmeEventAccel: (() => { try { const e = new DeviceMotionEvent('devicemotion', { acceleration: { x: 1, y: 2, z: 3 } }); return `${brand(e.acceleration)} x=${e.acceleration && e.acceleration.x}`; } catch (err) { return `ERR ${err.name}: ${err.message}`; } })(), dmeBare: (() => { try { const e = new DeviceMotionEvent('devicemotion'); return `accel=${String(e.acceleration)} rot=${String(e.rotationRate)} interval=${String(e.interval)}`; } catch (err) { return `ERR ${err.name}`; } })() }));

  // ---- Text tracks / media misc ------------------------------------------
  out.tracks = {};
  out.tracks.videoTextTracks = S(() => { const v = document.createElement('video'); return { list: brand(v.textTracks), len: v.textTracks.length }; });
  out.tracks.addTextTrack = S(() => { const v = document.createElement('video'); const t = v.addTextTrack('subtitles', 'L', 'en'); return { track: brand(t), kind: t.kind, label: t.label, language: t.language, id: t.id, mode: t.mode, cues: String(t.cues), activeCues: String(t.activeCues), listLen: v.textTracks.length, listItem: brand(v.textTracks[0]), byId: String(v.textTracks.getTrackById('')) }; });
  out.tracks.textTrackModeSet = S(() => { const v = document.createElement('video'); const t = v.addTextTrack('captions'); t.mode = 'showing'; return { mode: t.mode, cues: brand(t.cues), cuesLen: t.cues && t.cues.length, byId: String(t.cues && t.cues.getCueById('x')) }; });
  out.tracks.addTextTrackBadKind = S(() => document.createElement('video').addTextTrack('nope'));
  out.tracks.pipWindow = S(() => ({ typeofCtor: typeof PictureInPictureWindow, docPipEnabled: S(() => document.pictureInPictureEnabled), reqOnVideo: typeof document.createElement('video').requestPictureInPicture }));
  out.tracks.pipRequest = await T((() => { try { return document.createElement('video').requestPictureInPicture(); } catch (e) { return Promise.reject(e); } })());
  out.tracks.overconstrained = S(() => { const e = new OverconstrainedError('width', 'nope'); return { name: e.name, message: e.message, constraint: e.constraint, str: String(e), isDOMException: e instanceof DOMException, isError: e instanceof Error, code: e.code }; });
  out.tracks.overconstrainedBare = S(() => { const e = new OverconstrainedError('width'); return { name: e.name, message: JSON.stringify(e.message), constraint: e.constraint }; });
  out.tracks.captureController = S(() => { const c = new CaptureController(); return { own: Object.getOwnPropertyNames(c).join(','), zoomLevel: String(c.zoomLevel), onzoom: String(c.onzoomlevelchange), supported: JSON.stringify(c.getSupportedZoomLevels()), setFocus: S(() => c.setFocusBehavior('focus-captured-surface')), incr: S(() => c.increaseZoomLevel()), reset: S(() => c.resetZoomLevel()), fwdWheel: S(() => c.forwardWheel(null)) }; });
  out.tracks.cropTarget = await T((() => { try { return CropTarget.fromElement(document.body); } catch (e) { return Promise.reject(e); } })());
  out.tracks.browserCaptureTrack = S(() => typeof BrowserCaptureMediaStreamTrack);

  // ---- CSS / DOM misc -----------------------------------------------------
  out.cssdom = {};
  out.cssdom.highlight = S(() => { const h = new Highlight(); return { size: h.size, priority: h.priority, type: h.type, own: Object.getOwnPropertyNames(h).join(','), setType: S(() => { h.type = 'spelling-error'; return h.type; }), setBadType: S(() => { h.type = 'nope'; return h.type; }), setPriority: S(() => { h.priority = 3; return h.priority; }) }; });
  out.cssdom.highlightWithRange = S(() => { const r = new Range(); r.selectNodeContents(document.body); const h = new Highlight(r); return { size: h.size, has: h.has(r), addNonRange: S(() => h.add({})), iter: Array.from(h).map((x) => Object.prototype.toString.call(x)).join(','), del: h.delete(r), sizeAfter: h.size }; });
  out.cssdom.highlightRegistry = S(() => { const reg = CSS.highlights; return { brand: brand(reg), size: reg.size, set: S(() => { reg.set('a', new Highlight()); return reg.size; }), get: S(() => brand(reg.get('a'))), keys: Array.from(reg.keys()).join(','), entriesFirst: S(() => { const e = Array.from(reg.entries())[0]; return `${e[0]}=${Object.prototype.toString.call(e[1])}`; }), fromPoint: S(() => JSON.stringify(reg.highlightsFromPoint(1, 1))), del: S(() => reg.delete('a')) }; });
  out.cssdom.customStateSet = S(() => {
    class X extends HTMLElement { constructor() { super(); this.i = this.attachInternals(); } }
    customElements.define(`x-cs-${Math.random().toString(36).slice(2)}`, X);
    const el = new X();
    const s = el.i.states;
    return { brand: brand(s), size: s.size, add: S(() => { s.add('--on'); return s.size; }), has: s.has('--on'), addBad: S(() => s.add('nope')), iter: Array.from(s).join(','), del: S(() => s.delete('--on')), clear: S(() => { s.clear(); return s.size; }) };
  });
  out.cssdom.mathml = S(() => { const m = document.createElementNS('http://www.w3.org/1998/Math/MathML', 'math'); return { brand: brand(m), ns: m.namespaceURI, tag: m.tagName, localName: m.localName, isMathML: m instanceof MathMLElement, isElement: m instanceof Element, isHTML: m instanceof HTMLElement, style: brand(m.style), focus: typeof m.focus }; });
  out.cssdom.mathmlInHtml = S(() => { const d = document.createElement('div'); d.innerHTML = '<math><mi>x</mi></math>'; const m = d.firstElementChild; return { brand: brand(m), ns: m.namespaceURI, childBrand: brand(m.firstElementChild) }; });
  out.cssdom.xslt = S(() => { const p = new XSLTProcessor(); return { own: Object.getOwnPropertyNames(p).join(','), setParam: S(() => p.setParameter(null, 'a', 'b')), getParam: S(() => p.getParameter(null, 'a')), getMissing: String(p.getParameter(null, 'zz')), reset: S(() => p.reset()), afterReset: String(p.getParameter(null, 'a')), importBad: S(() => p.importStylesheet({})), transformNoSheet: S(() => p.transformToFragment(document, document)) }; });
  out.cssdom.xsltReal = S(() => {
    const xsl = new DOMParser().parseFromString('<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"><xsl:template match="/"><out/></xsl:template></xsl:stylesheet>', 'application/xml');
    const src = new DOMParser().parseFromString('<in/>', 'application/xml');
    const p = new XSLTProcessor();
    p.importStylesheet(xsl);
    const doc = p.transformToDocument(src);
    return { doc: brand(doc), root: doc && doc.documentElement && doc.documentElement.tagName, frag: brand(p.transformToFragment(src, document)) };
  });
  out.cssdom.sanitizer = S(() => { const s = new Sanitizer(); const cfg = s.get(); return { own: Object.getOwnPropertyNames(s).join(','), cfgKeys: cfg && Object.keys(cfg).join(','), cfgSample: JSON.stringify(cfg).slice(0, 200), allowEl: S(() => { s.allowElement('div'); return JSON.stringify(s.get()).slice(0, 120); }), removeUnsafe: S(() => s.removeUnsafe()), setComments: S(() => s.setComments(true)) }; });
  out.cssdom.sanitizerPreset = S(() => brand(new Sanitizer({ elements: ['div'] })));
  out.cssdom.domError = S(() => { const e = new DOMError('AbortError', 'msg'); return { name: e.name, message: e.message, own: Object.getOwnPropertyNames(e).join(','), str: String(e), isError: e instanceof Error }; });
  out.cssdom.domErrorBare = S(() => { const e = new DOMError('X'); return { name: e.name, message: JSON.stringify(e.message) }; });

  // ---- window misc / navigation -------------------------------------------
  out.misc = {};
  out.misc.urlPatternBare = S(() => { const p = new URLPattern(); return { protocol: p.protocol, username: p.username, password: p.password, hostname: p.hostname, port: p.port, pathname: p.pathname, search: p.search, hash: p.hash, hasRegExpGroups: p.hasRegExpGroups }; });
  out.misc.urlPatternObj = S(() => { const p = new URLPattern({ pathname: '/books/:id' }); return { pathname: p.pathname, protocol: p.protocol, test: p.test('https://x.com/books/7'), testNo: p.test('https://x.com/n'), exec: JSON.stringify(p.exec('https://x.com/books/7')) }; });
  out.misc.urlPatternStr = S(() => { const p = new URLPattern('https://example.com/a/:b'); return { protocol: p.protocol, hostname: p.hostname, pathname: p.pathname, test: p.test('https://example.com/a/z') }; });
  out.misc.urlPatternBase = S(() => { const p = new URLPattern('/x/:y', 'https://base.test/'); return { hostname: p.hostname, pathname: p.pathname, hasRegExpGroups: p.hasRegExpGroups }; });
  out.misc.urlPatternBad = S(() => new URLPattern('{'));
  out.misc.urlPatternRegexGroups = S(() => new URLPattern({ pathname: '/(\\d+)' }).hasRegExpGroups);
  out.misc.option = S(() => { const o = new Option(); return { brand: Object.prototype.toString.call(o), tag: o.tagName, text: JSON.stringify(o.text), value: JSON.stringify(o.value), selected: o.selected, defaultSelected: o.defaultSelected, index: o.index, form: String(o.form), label: JSON.stringify(o.label), ctorIsHTMLOption: Option === HTMLOptionElement, isHTMLOption: o instanceof HTMLOptionElement }; });
  out.misc.optionArgs = S(() => { const o = new Option('T', 'V', true, true); return { text: o.text, value: o.value, defaultSelected: o.defaultSelected, selected: o.selected, html: o.outerHTML }; });
  out.misc.optionInSelect = S(() => { const s = document.createElement('select'); s.appendChild(new Option('a', '1')); return { len: s.options.length, index: s.options[0].index, value: s.value }; });
  out.misc.profiler = await (async () => { try { const p = new Profiler({ sampleInterval: 10, maxBufferSize: 100 }); const r = { brand: brand(p), sampleInterval: p.sampleInterval, stopped: p.stopped, own: Object.getOwnPropertyNames(p).join(',') }; r.stop = await T(p.stop()); r.stoppedAfter = p.stopped; return r; } catch (e) { return `${e.name}: ${e.message}`; } })();
  out.misc.profilerBadInit = S(() => new Profiler({}));
  out.misc.profilerNonDict = S(() => new Profiler(5));
  out.misc.eyeDropper = await (async () => { try { const d = new EyeDropper(); return { own: Object.getOwnPropertyNames(d).join(','), open: await T(d.open(), 800) }; } catch (e) { return `${e.name}: ${e.message}`; } })();
  out.misc.idleDetector = await (async () => { try { const d = new IdleDetector(); const r = { userState: String(d.userState), screenState: String(d.screenState), onchange: String(d.onchange), own: Object.getOwnPropertyNames(d).join(',') }; r.start = await T(d.start({ threshold: 60000 }), 800); r.startBadThreshold = await T((() => { try { return d.start({ threshold: 10 }); } catch (e) { return Promise.reject(e); } })(), 500); r.perm = await T(IdleDetector.requestPermission(), 800); return r; } catch (e) { return `${e.name}: ${e.message}`; } })();
  out.misc.inputDeviceCaps = S(() => { const c = new InputDeviceCapabilities(); const d = new InputDeviceCapabilities({ firesTouchEvents: true }); return { bare: c.firesTouchEvents, set: d.firesTouchEvents, own: Object.getOwnPropertyNames(c).join(','), onUiEvent: (() => { const e = new UIEvent('click'); return String(e.sourceCapabilities); })() }; });
  out.misc.reportingObserver = await (async () => {
    try {
      const seen = [];
      const o = new ReportingObserver((reports) => seen.push(reports.length), { types: ['deprecation'], buffered: true });
      const r = { own: Object.getOwnPropertyNames(o).join(','), observe: S(() => o.observe()), takeRecords: JSON.stringify(o.takeRecords()), disconnect: S(() => o.disconnect()) };
      r.noCallback = S(() => new ReportingObserver());
      r.nonFn = S(() => new ReportingObserver(5));
      r.badTypes = S(() => brand(new ReportingObserver(() => {}, { types: 'nope' })));
      return r;
    } catch (e) { return `${e.name}: ${e.message}`; }
  })();
  out.misc.clipboardItem = await (async () => {
    try {
      const it = new ClipboardItem({ 'text/plain': new Blob(['hi'], { type: 'text/plain' }) });
      const r = { types: JSON.stringify(it.types), own: Object.getOwnPropertyNames(it).join(','), supports: [ClipboardItem.supports('text/plain'), ClipboardItem.supports('image/png'), ClipboardItem.supports('application/x-nope')].join(','), supportsNoArg: S(() => ClipboardItem.supports()) };
      r.getType = await T(it.getType('text/plain'));
      r.getTypeMissing = await T(it.getType('image/png'));
      r.fromString = S(() => JSON.stringify(new ClipboardItem({ 'text/plain': 'plain string' }).types));
      r.empty = S(() => JSON.stringify(new ClipboardItem({}).types));
      r.nonDict = S(() => new ClipboardItem('x'));
      return r;
    } catch (e) { return `${e.name}: ${e.message}`; }
  })();
  out.misc.keyframeEffect = S(() => {
    const el = document.createElement('div');
    const k = new KeyframeEffect(el, [{ opacity: 0 }, { opacity: 1 }], { duration: 500, iterations: 2 });
    return { brand: brand(k), target: brand(k.target), pseudoElement: String(k.pseudoElement), composite: k.composite, keyframes: JSON.stringify(k.getKeyframes()), timing: JSON.stringify(k.getTiming ? k.getTiming() : 'no getTiming'), computed: JSON.stringify(k.getComputedTiming ? k.getComputedTiming() : 'none'), setKeyframes: S(() => { k.setKeyframes([{ opacity: 0.5 }]); return JSON.stringify(k.getKeyframes()); }) };
  });
  out.misc.keyframeEffectNullTarget = S(() => { const k = new KeyframeEffect(null, null); return { target: String(k.target), keyframes: JSON.stringify(k.getKeyframes()), timing: JSON.stringify(k.getTiming && k.getTiming()) }; });
  out.misc.keyframeEffectFromEffect = S(() => brand(new KeyframeEffect(new KeyframeEffect(null, null))));
  out.misc.keyframeEffectViaAnimate = S(() => { const a = document.createElement('div').animate([{ opacity: 0 }, { opacity: 1 }], 300); return { effect: brand(a.effect), isKeyframeEffect: a.effect instanceof KeyframeEffect }; });
  out.misc.idbOpen = S(() => { const r = indexedDB.open(`p15-${Math.random().toString(36).slice(2)}`); return { brand: brand(r), isOpenDB: r instanceof IDBOpenDBRequest, isRequest: r instanceof IDBRequest, onblocked: String(r.onblocked), onupgradeneeded: String(r.onupgradeneeded), readyState: r.readyState, own: Object.getOwnPropertyNames(r).join(',') }; });
  out.misc.idbDelete = S(() => brand(indexedDB.deleteDatabase('p15-nope')));
  out.misc.navigation = S(() => ({ nav: brand(window.navigation), transition: String(window.navigation && window.navigation.transition), currentEntry: brand(window.navigation && window.navigation.currentEntry), destinationCtor: typeof NavigationDestination, transitionCtor: typeof NavigationTransition }));
  out.misc.openDatabase = String(typeof window.openDatabase);
  return out;
})()
