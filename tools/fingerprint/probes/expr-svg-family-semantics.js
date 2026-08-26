// What the 53 members this batch adds actually answer, read off a live
// document rather than off the IDL.
//
// The member table says which names are short; it says nothing about what
// `suspendRedraw` returns, whether `currentScale` has a setter, what
// `<use>`'s width defaults to, or which of these are accessors and which are
// data properties. B50 wrote a test from the answer that "looked right" for
// `ScreenOrientation.lock` and had to re-measure; this reads all of it from
// both arms instead.
(() => {
  const NS = 'http://www.w3.org/2000/svg';
  const host = document.createElement('div');
  host.innerHTML =
    '<svg id="root" width="200" height="100" viewBox="0 0 200 100" xmlns="' + NS + '">' +
    '<a id="a" href="#x" target="_top" download="d" ping="/p" rel="noopener" hreflang="en" type="text/html" referrerpolicy="no-referrer"><circle id="c" cx="10" cy="10" r="5"/></a>' +
    '<image id="img" href="#i" x="1" y="2" width="30" height="40" preserveAspectRatio="xMidYMid slice" decoding="async" crossorigin="anonymous"/>' +
    '<use id="use" href="#c" x="3" y="4" width="50" height="60"/>' +
    '<path id="path" d="M0 0 L 40 0 L 40 40 Z" stroke-width="4"/>' +
    '<text id="text" x="5" y="20" font-size="16">Hello</text>' +
    '<mask id="mask" requiredExtensions="urn:a" systemLanguage="en"/>' +
    '<view id="view" viewBox="0 0 10 10"/>' +
    '</svg>';
  document.body.appendChild(host);
  const $ = (id) => host.querySelector('#' + id);

  const out = {};
  const call = (label, fn) => {
    try {
      const v = fn();
      out[label] = describe(v);
    } catch (e) {
      out[label] = 'throw ' + e.constructor.name + ': ' + e.message;
    }
  };
  const describe = (v) => {
    if (v === null) return 'null';
    if (v === undefined) return 'undefined';
    const t = typeof v;
    if (t === 'number' || t === 'boolean' || t === 'string') return t + ' ' + String(v);
    if (t === 'function') return 'function ' + v.name + '/' + v.length;
    let name = 'object';
    try { name = Object.getPrototypeOf(v)?.constructor?.name ?? 'null-proto'; } catch (e) { /* */ }
    return name;
  };

  // Descriptor kind and function arity for every name this batch adds, so the
  // shape is measured alongside the behaviour.
  const shape = (iface, names) => {
    const proto = self[iface]?.prototype;
    for (const n of names) {
      const d = proto && Object.getOwnPropertyDescriptor(proto, n);
      if (!d) { out[iface + '.' + n + ' [desc]'] = 'absent'; continue; }
      out[iface + '.' + n + ' [desc]'] =
        (d.get ? 'accessor get' + (d.set ? '+set' : '') : 'data ' + describe(d.value)) +
        ' enum=' + d.enumerable + ' conf=' + d.configurable +
        (d.get ? ' getlen=' + d.get.length : '');
    }
  };

  shape('SVGSVGElement', ['currentScale', 'currentTranslate', 'zoomAndPan', 'SVG_ZOOMANDPAN_UNKNOWN',
    'SVG_ZOOMANDPAN_DISABLE', 'SVG_ZOOMANDPAN_MAGNIFY', 'animationsPaused', 'checkEnclosure',
    'checkIntersection', 'deselectAll', 'forceRedraw', 'getCurrentTime', 'getEnclosureList',
    'getIntersectionList', 'pauseAnimations', 'setCurrentTime', 'suspendRedraw', 'unpauseAnimations',
    'unsuspendRedraw', 'unsuspendRedrawAll']);
  shape('SVGViewElement', ['zoomAndPan', 'SVG_ZOOMANDPAN_UNKNOWN', 'SVG_ZOOMANDPAN_DISABLE', 'SVG_ZOOMANDPAN_MAGNIFY']);
  shape('SVGAElement', ['target', 'download', 'ping', 'rel', 'hreflang', 'type', 'referrerPolicy', 'interestForElement']);
  shape('SVGImageElement', ['x', 'y', 'width', 'height', 'preserveAspectRatio', 'decoding', 'crossOrigin', 'decode']);
  shape('SVGUseElement', ['x', 'y', 'width', 'height']);
  shape('SVGGeometryElement', ['isPointInFill', 'isPointInStroke']);
  shape('SVGTextContentElement', ['getCharNumAtPosition', 'getEndPositionOfChar', 'getRotationOfChar',
    'getStartPositionOfChar', 'selectSubString']);
  shape('SVGMaskElement', ['requiredExtensions', 'systemLanguage']);

  const root = $('root');
  call('svg.currentScale', () => root.currentScale);
  call('svg.currentScale = 2', () => { root.currentScale = 2; return root.currentScale; });
  call('svg.currentTranslate', () => root.currentTranslate);
  call('svg.currentTranslate.x', () => root.currentTranslate.x);
  call('svg.currentTranslate same object', () => root.currentTranslate === root.currentTranslate);
  call('svg.currentTranslate.x = 5', () => { root.currentTranslate.x = 5; return root.currentTranslate.x; });
  call('svg.zoomAndPan', () => root.zoomAndPan);
  call('svg.zoomAndPan = 1', () => { root.zoomAndPan = 1; return [root.zoomAndPan, root.getAttribute('zoomAndPan')].join('|'); });
  call('svg.zoomAndPan = 0', () => { root.zoomAndPan = 0; return root.zoomAndPan; });
  call('svg[zoomAndPan=disable]', () => { root.setAttribute('zoomAndPan', 'disable'); return root.zoomAndPan; });
  call('svg.SVG_ZOOMANDPAN_MAGNIFY', () => root.SVG_ZOOMANDPAN_MAGNIFY);
  call('svg.animationsPaused()', () => root.animationsPaused());
  call('svg.getCurrentTime()', () => root.getCurrentTime());
  call('svg.pauseAnimations()', () => root.pauseAnimations());
  call('svg.animationsPaused() after pause', () => root.animationsPaused());
  call('svg.unpauseAnimations()', () => root.unpauseAnimations());
  call('svg.setCurrentTime(3)', () => root.setCurrentTime(3));
  call('svg.getCurrentTime() after set', () => root.getCurrentTime());
  call('svg.setCurrentTime()', () => root.setCurrentTime());
  call('svg.suspendRedraw(100)', () => root.suspendRedraw(100));
  call('svg.suspendRedraw(100) twice', () => root.suspendRedraw(100));
  call('svg.unsuspendRedraw(1)', () => root.unsuspendRedraw(1));
  call('svg.unsuspendRedraw(9999)', () => root.unsuspendRedraw(9999));
  call('svg.unsuspendRedrawAll()', () => root.unsuspendRedrawAll());
  call('svg.forceRedraw()', () => root.forceRedraw());
  call('svg.deselectAll()', () => root.deselectAll());
  call('svg.getIntersectionList(rect,null)', () => root.getIntersectionList(root.createSVGRect(), null));
  call('svg.getIntersectionList length', () => root.getIntersectionList(root.createSVGRect(), null).length);
  call('svg.getEnclosureList(rect,null)', () => root.getEnclosureList(root.createSVGRect(), null));
  call('svg.checkIntersection(circle,rect)', () => root.checkIntersection($('c'), root.createSVGRect()));
  call('svg.checkEnclosure(circle,rect)', () => root.checkEnclosure($('c'), root.createSVGRect()));
  call('svg.checkIntersection()', () => root.checkIntersection());

  const a = $('a');
  call('a.target', () => a.target);
  call('a.target.baseVal', () => a.target.baseVal);
  call('a.target same object', () => a.target === a.target);
  call('a.download', () => a.download);
  call('a.ping', () => a.ping);
  call('a.rel', () => a.rel);
  call('a.hreflang', () => a.hreflang);
  call('a.type', () => a.type);
  call('a.referrerPolicy', () => a.referrerPolicy);
  call('a.referrerPolicy bogus', () => { a.setAttribute('referrerpolicy', 'bogus'); return a.referrerPolicy; });
  call('a.interestForElement', () => a.interestForElement);
  call('a.download = z', () => { a.download = 'z'; return a.getAttribute('download'); });
  call('a.rel = nofollow', () => { a.rel = 'nofollow'; return [a.getAttribute('rel'), a.relList.value].join('|'); });
  call('a.target = _blank', () => { a.target = '_blank'; return a.getAttribute('target'); });

  const img = $('img');
  for (const n of ['x', 'y', 'width', 'height']) {
    call('image.' + n, () => img[n]);
    call('image.' + n + '.baseVal.value', () => img[n].baseVal.value);
  }
  call('image.preserveAspectRatio', () => img.preserveAspectRatio);
  call('image.preserveAspectRatio.baseVal.align', () => img.preserveAspectRatio.baseVal.align);
  call('image.decoding', () => img.decoding);
  call('image.decoding bogus', () => { img.setAttribute('decoding', 'bogus'); return img.decoding; });
  call('image.crossOrigin', () => img.crossOrigin);
  call('image.crossOrigin bogus', () => { img.setAttribute('crossorigin', 'bogus'); return img.crossOrigin; });
  call('image.decode()', () => img.decode());
  call('image.decoding = sync', () => { img.decoding = 'sync'; return img.getAttribute('decoding'); });

  const use = $('use');
  for (const n of ['x', 'y', 'width', 'height']) {
    call('use.' + n + '.baseVal.value', () => use[n].baseVal.value);
  }
  const bare = document.createElementNS(NS, 'use');
  for (const n of ['x', 'y', 'width', 'height']) {
    call('bare use.' + n + '.baseVal.value', () => bare[n].baseVal.value);
    call('bare use.' + n + '.baseVal.unitType', () => bare[n].baseVal.unitType);
  }
  const bareImage = document.createElementNS(NS, 'image');
  for (const n of ['x', 'y', 'width', 'height']) {
    call('bare image.' + n + '.baseVal.value', () => bareImage[n].baseVal.value);
  }

  const path = $('path');
  const pt = root.createSVGPoint();
  pt.x = 10; pt.y = 5;
  call('path.isPointInFill(10,5)', () => path.isPointInFill(pt));
  call('path.isPointInStroke(10,5)', () => path.isPointInStroke(pt));
  const out1 = root.createSVGPoint(); out1.x = 500; out1.y = 500;
  call('path.isPointInFill(500,500)', () => path.isPointInFill(out1));
  call('path.isPointInStroke(500,500)', () => path.isPointInStroke(out1));
  call('path.isPointInFill()', () => path.isPointInFill());
  call('path.isPointInStroke()', () => path.isPointInStroke());
  const onEdge = root.createSVGPoint(); onEdge.x = 40; onEdge.y = 20;
  call('path.isPointInStroke(40,20)', () => path.isPointInStroke(onEdge));

  const text = $('text');
  call('text.getCharNumAtPosition()', () => text.getCharNumAtPosition());
  const at = root.createSVGPoint(); at.x = 8; at.y = 16;
  call('text.getCharNumAtPosition(8,16)', () => text.getCharNumAtPosition(at));
  const far = root.createSVGPoint(); far.x = 900; far.y = 900;
  call('text.getCharNumAtPosition(900,900)', () => text.getCharNumAtPosition(far));
  call('text.getStartPositionOfChar(0)', () => text.getStartPositionOfChar(0));
  call('text.getStartPositionOfChar(0).x', () => text.getStartPositionOfChar(0).x);
  call('text.getStartPositionOfChar(0).y', () => text.getStartPositionOfChar(0).y);
  call('text.getStartPositionOfChar(1).x', () => text.getStartPositionOfChar(1).x);
  call('text.getEndPositionOfChar(0).x', () => text.getEndPositionOfChar(0).x);
  call('text.getEndPositionOfChar(0).y', () => text.getEndPositionOfChar(0).y);
  call('text.getStartPositionOfChar(99)', () => text.getStartPositionOfChar(99));
  call('text.getEndPositionOfChar(99)', () => text.getEndPositionOfChar(99));
  call('text.getRotationOfChar(0)', () => text.getRotationOfChar(0));
  call('text.getRotationOfChar(99)', () => text.getRotationOfChar(99));
  call('text.selectSubString(0,2)', () => text.selectSubString(0, 2));
  call('text.selectSubString(99,2)', () => text.selectSubString(99, 2));
  call('selection after selectSubString', () => String(getSelection()));
  call('text.selectSubString()', () => text.selectSubString());

  const mask = $('mask');
  call('mask.requiredExtensions', () => mask.requiredExtensions);
  call('mask.requiredExtensions.getItem(0)', () => mask.requiredExtensions.getItem(0));
  call('mask.requiredExtensions same object', () => mask.requiredExtensions === mask.requiredExtensions);
  call('mask.systemLanguage.numberOfItems', () => mask.systemLanguage.numberOfItems);

  const view = $('view');
  call('view.zoomAndPan', () => view.zoomAndPan);
  call('view[zoomAndPan=disable]', () => { view.setAttribute('zoomAndPan', 'disable'); return view.zoomAndPan; });
  call('view.SVG_ZOOMANDPAN_DISABLE', () => view.SVG_ZOOMANDPAN_DISABLE);

  host.remove();
  return JSON.stringify(out);
})()
