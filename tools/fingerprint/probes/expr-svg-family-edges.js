// The follow-up questions the first SVG-family reading left open: which
// content attribute each reflected member actually reads (SVG attributes are
// case-sensitive, so `referrerpolicy` and `referrerPolicy` are two names), what
// the geometry calls answer for a box that really does overlap, and the name
// -- not just the message -- of the DOMException the text calls throw.
(() => {
  const NS = 'http://www.w3.org/2000/svg';
  const host = document.createElement('div');
  host.innerHTML =
    '<svg id="root" width="200" height="100" viewBox="0 0 200 100" xmlns="' + NS + '">' +
    '<a id="a"><circle id="c" cx="10" cy="10" r="5"/></a>' +
    '<rect id="r" x="0" y="0" width="20" height="20"/>' +
    '<image id="img"/>' +
    '<text id="text" x="5" y="20" font-size="16">Hello</text>' +
    '<view id="view" zoomAndPan="disable"/>' +
    '</svg>';
  document.body.appendChild(host);
  const $ = (id) => host.querySelector('#' + id);
  const out = {};
  const call = (label, fn) => {
    try {
      const v = fn();
      if (v === null) { out[label] = 'null'; return; }
      if (v === undefined) { out[label] = 'undefined'; return; }
      const t = typeof v;
      if (t === 'object') {
        out[label] = (Object.getPrototypeOf(v)?.constructor?.name ?? 'object');
        return;
      }
      out[label] = t + ' ' + String(v);
    } catch (e) {
      out[label] = (e.name || e.constructor.name) + ': ' + e.message;
    }
  };

  const a = $('a');
  // Which spelling each one reads. Set the lowercase form and the camelCase
  // form separately and see which one the IDL attribute follows.
  for (const [prop, lower, camel] of [
    ['download', 'download', 'downLoad'],
    ['ping', 'ping', 'Ping'],
    ['rel', 'rel', 'Rel'],
    ['hreflang', 'hreflang', 'hrefLang'],
    ['type', 'type', 'Type'],
    ['referrerPolicy', 'referrerpolicy', 'referrerPolicy'],
  ]) {
    call('a.' + prop + ' missing', () => a[prop]);
    call('a.' + prop + ' <- ' + lower, () => { a.setAttribute(lower, 'L'); return a[prop]; });
    a.removeAttribute(lower);
    call('a.' + prop + ' <- ' + camel, () => { a.setAttribute(camel, 'C'); return a[prop]; });
    a.removeAttribute(camel);
    call('a.' + prop + ' = W writes', () => { a[prop] = 'W'; return [a.getAttribute(lower), a.getAttribute(camel)].join('|'); });
    a.removeAttribute(lower); a.removeAttribute(camel);
  }
  call('a.target missing', () => a.target.baseVal);
  call('a.target <- Target', () => { a.setAttribute('Target', 'C'); return a.target.baseVal; });
  a.removeAttribute('Target');
  call('a.target <- target', () => { a.setAttribute('target', 'L'); return a.target.baseVal; });

  const img = $('img');
  call('image.decoding missing', () => img.decoding);
  call('image.crossOrigin missing', () => img.crossOrigin);
  call('image.crossOrigin use-credentials', () => { img.setAttribute('crossorigin', 'use-credentials'); return img.crossOrigin; });
  call('image.crossOrigin empty', () => { img.setAttribute('crossorigin', ''); return img.crossOrigin; });
  call('image.crossOrigin = null', () => { img.crossOrigin = null; return [String(img.crossOrigin), String(img.getAttribute('crossorigin'))].join('|'); });
  call('image.decoding <- Decoding', () => { img.setAttribute('Decoding', 'sync'); return img.decoding; });
  img.removeAttribute('Decoding');
  call('image.preserveAspectRatio missing align', () => img.preserveAspectRatio.baseVal.align);

  const root = $('root');
  call('svg.zoomAndPan with attr, then set', () => {
    root.setAttribute('zoomAndPan', 'disable');
    root.zoomAndPan = 2;
    return [root.zoomAndPan, String(root.getAttribute('zoomAndPan'))].join('|');
  });
  call('svg.zoomAndPan attr removed after set', () => {
    root.removeAttribute('zoomAndPan');
    return root.zoomAndPan;
  });
  call('svg.zoomAndPan bogus attr', () => { root.setAttribute('zoomAndPan', 'bogus'); return root.zoomAndPan; });
  call('svg.zoomAndPan magnify attr', () => { root.setAttribute('zoomAndPan', 'magnify'); return root.zoomAndPan; });
  call('svg.zoomAndPan MAGNIFY caps attr', () => { root.setAttribute('zoomAndPan', 'DISABLE'); return root.zoomAndPan; });
  root.removeAttribute('zoomAndPan');
  call('svg.zoomAndPan = 7', () => { root.zoomAndPan = 7; return root.zoomAndPan; });
  call('svg.currentScale = 0', () => { root.currentScale = 0; return root.currentScale; });
  call('svg.currentScale = -3', () => { root.currentScale = -3; return root.currentScale; });
  root.currentScale = 1;
  call('inner svg currentScale', () => {
    const inner = document.createElementNS(NS, 'svg');
    root.appendChild(inner);
    const before = inner.currentScale;
    inner.currentScale = 4;
    const after = inner.currentScale;
    inner.remove();
    return [before, after].join('|');
  });

  const mk = (x, y, w, h) => { const r = root.createSVGRect(); r.x = x; r.y = y; r.width = w; r.height = h; return r; };
  call('checkIntersection(rect, 0,0,200,100)', () => root.checkIntersection($('r'), mk(0, 0, 200, 100)));
  call('checkIntersection(rect, 100,50,10,10)', () => root.checkIntersection($('r'), mk(100, 50, 10, 10)));
  call('checkEnclosure(rect, 0,0,200,100)', () => root.checkEnclosure($('r'), mk(0, 0, 200, 100)));
  call('checkEnclosure(rect, 0,0,10,10)', () => root.checkEnclosure($('r'), mk(0, 0, 10, 10)));
  call('checkIntersection(rect, 10,10,5,5)', () => root.checkIntersection($('r'), mk(10, 10, 5, 5)));
  call('getIntersectionList(0,0,200,100).length', () => root.getIntersectionList(mk(0, 0, 200, 100), null).length);
  call('getIntersectionList(0,0,200,100)[0]', () => root.getIntersectionList(mk(0, 0, 200, 100), null)[0]?.id);
  call('getIntersectionList(0,0,200,100) ids', () =>
    Array.from(root.getIntersectionList(mk(0, 0, 200, 100), null)).map((e) => e.id).join(','));
  call('getEnclosureList(0,0,200,100) ids', () =>
    Array.from(root.getEnclosureList(mk(0, 0, 200, 100), null)).map((e) => e.id).join(','));
  call('getIntersectionList(500,500,1,1).length', () => root.getIntersectionList(mk(500, 500, 1, 1), null).length);
  call('getIntersectionList ref=a ids', () =>
    Array.from(root.getIntersectionList(mk(0, 0, 200, 100), $('a'))).map((e) => e.id).join(','));
  call('getIntersectionList live?', () => {
    const list = root.getIntersectionList(mk(0, 0, 200, 100), null);
    const before = list.length;
    const extra = document.createElementNS(NS, 'rect');
    extra.setAttribute('width', '5'); extra.setAttribute('height', '5');
    root.appendChild(extra);
    const after = list.length;
    extra.remove();
    return [before, after].join('|');
  });

  const text = $('text');
  call('text.getStartPositionOfChar(5)', () => text.getStartPositionOfChar(5).x);
  call('text.getStartPositionOfChar(4).x', () => text.getStartPositionOfChar(4).x);
  call('text.getEndPositionOfChar(4).x', () => text.getEndPositionOfChar(4).x);
  call('text.getStartPositionOfChar(-1)', () => text.getStartPositionOfChar(-1).x);
  call('text.getRotationOfChar(5)', () => text.getRotationOfChar(5));
  call('text.selectSubString(0,99)', () => text.selectSubString(0, 99));
  call('selection after (0,99)', () => String(getSelection()));
  call('text.selectSubString(5,1)', () => text.selectSubString(5, 1));
  call('text.getCharNumAtPosition(x=6,y=20)', () => { const p = root.createSVGPoint(); p.x = 6; p.y = 20; return text.getCharNumAtPosition(p); });
  call('text.getCharNumAtPosition(x=60,y=20)', () => { const p = root.createSVGPoint(); p.x = 60; p.y = 20; return text.getCharNumAtPosition(p); });
  call('text.getCharNumAtPosition(x=5,y=0)', () => { const p = root.createSVGPoint(); p.x = 5; p.y = 0; return text.getCharNumAtPosition(p); });
  call('empty text getStartPositionOfChar(0)', () => {
    const t = document.createElementNS(NS, 'text');
    root.appendChild(t);
    try { return t.getStartPositionOfChar(0).x; } finally { t.remove(); }
  });

  const view = $('view');
  call('view.zoomAndPan = 2', () => { view.zoomAndPan = 2; return [view.zoomAndPan, String(view.getAttribute('zoomAndPan'))].join('|'); });

  host.remove();
  return JSON.stringify(out);
})()
