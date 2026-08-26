// The last 63 names on the window table's missing pile, spread over eighteen
// interfaces with nothing in common but being short. Same discipline as the
// SVG and HTML batches: descriptor kind and arity for every name, then what it
// answers on a live document.
(() => {
  const out = {};
  const describe = (v) => {
    if (v === null) return 'null';
    if (v === undefined) return 'undefined';
    const t = typeof v;
    if (t === 'number' || t === 'boolean' || t === 'string') return t + ' ' + String(v);
    if (t === 'function') return 'function ' + v.name + '/' + v.length;
    if (Array.isArray(v)) return 'array [' + v.join(',') + ']';
    let name = 'object';
    try { name = Object.getPrototypeOf(v)?.constructor?.name ?? 'null-proto'; } catch (e) { /* */ }
    return name;
  };
  const call = (label, fn) => {
    try { out[label] = describe(fn()); } catch (e) { out[label] = (e.name || e.constructor.name) + ': ' + e.message; }
  };
  const shape = (iface, names) => {
    const proto = self[iface]?.prototype;
    for (const n of names) {
      const d = proto && Object.getOwnPropertyDescriptor(proto, n);
      if (!d) { out[iface + '.' + n + ' [desc]'] = 'absent'; continue; }
      out[iface + '.' + n + ' [desc]'] =
        (d.get ? 'accessor get' + (d.set ? '+set' : '') : 'data ' + describe(d.value)) +
        ' enum=' + d.enumerable + ' conf=' + d.configurable;
    }
  };

  shape('Request', ['destination', 'referrer', 'referrerPolicy', 'mode', 'integrity', 'keepalive',
    'duplex', 'isHistoryNavigation', 'targetAddressSpace', 'isReloadNavigation', 'textStream']);
  shape('ProcessingInstruction', ['sheet', 'getAttribute', 'getAttributeNames', 'hasAttribute',
    'hasAttributes', 'removeAttribute', 'setAttribute', 'toggleAttribute']);
  shape('IntersectionObserver', ['root', 'rootMargin', 'scrollMargin', 'thresholds', 'delay', 'trackVisibility']);
  shape('FontFace', ['ascentOverride', 'descentOverride', 'lineGapOverride', 'sizeAdjust', 'variationSettings']);
  shape('Selection', ['baseNode', 'baseOffset', 'extentNode', 'extentOffset', 'getComposedRanges']);
  shape('Navigation', ['onnavigate', 'onnavigatesuccess', 'onnavigateerror', 'reload']);
  shape('DocumentType', ['after', 'before', 'replaceWith']);
  shape('IDBDatabase', ['onabort', 'onclose', 'onversionchange']);
  shape('NamedNodeMap', ['getNamedItemNS', 'removeNamedItemNS', 'setNamedItemNS']);
  shape('VisualViewport', ['onresize', 'onscroll', 'onscrollend']);
  shape('CustomElementRegistry', ['getName', 'initialize']);
  shape('DOMMatrixReadOnly', ['toJSON', 'transformPoint']);
  shape('DataTransferItem', ['webkitGetAsEntry', 'getAsFileSystemHandle']);
  shape('IDBVersionChangeEvent', ['dataLoss', 'dataLossMessage']);
  shape('WebTransportDatagramDuplexStream', ['incomingMaxBufferedDatagrams', 'outgoingMaxBufferedDatagrams']);
  shape('EventTarget', ['when']);
  shape('Date', ['toTemporalInstant']);

  // Where `constructor` sits on Navigator, which is the whole of that
  // interface's difference.
  call('Navigator constructor index', () => Object.getOwnPropertyNames(Navigator.prototype).indexOf('constructor'));
  call('Navigator member before constructor', () => {
    const names = Object.getOwnPropertyNames(Navigator.prototype);
    return names[names.indexOf('constructor') - 1];
  });

  const request = new Request('/x');
  for (const n of ['destination', 'referrer', 'referrerPolicy', 'mode', 'integrity', 'keepalive',
    'duplex', 'isHistoryNavigation', 'targetAddressSpace', 'isReloadNavigation']) {
    call('request.' + n, () => request[n]);
  }
  call('request.textStream', () => request.textStream);
  call('request with options mode', () => new Request('/x', { mode: 'no-cors' }).mode);
  call('request with options referrer', () => new Request('/x', { referrer: '' }).referrer);
  call('request with options keepalive', () => new Request('/x', { keepalive: true }).keepalive);
  call('request with options integrity', () => new Request('/x', { integrity: 'sha256-x' }).integrity);
  call('request with body duplex', () => new Request('/x', { method: 'POST', body: 'b' }).duplex);
  call('request referrerPolicy set', () => new Request('/x', { referrerPolicy: 'no-referrer' }).referrerPolicy);

  const pi = document.createProcessingInstruction('xml-stylesheet', 'href="/s.css"');
  call('pi.sheet', () => pi.sheet);
  call('pi.getAttribute(href)', () => pi.getAttribute('href'));
  call('pi.getAttributeNames()', () => pi.getAttributeNames());
  call('pi.hasAttribute(href)', () => pi.hasAttribute('href'));
  call('pi.hasAttributes()', () => pi.hasAttributes());
  call('pi.setAttribute(a,b)', () => pi.setAttribute('a', 'b'));
  call('pi.getAttribute(a) after set', () => pi.getAttribute('a'));
  call('pi.getAttributeNames() after set', () => pi.getAttributeNames());
  call('pi.toggleAttribute(t)', () => pi.toggleAttribute('t'));
  call('pi.hasAttribute(t)', () => pi.hasAttribute('t'));
  call('pi.removeAttribute(a)', () => pi.removeAttribute('a'));
  call('pi.getAttribute(a) after remove', () => pi.getAttribute('a'));

  const io = new IntersectionObserver(() => {});
  call('io.root', () => io.root);
  call('io.rootMargin', () => io.rootMargin);
  call('io.scrollMargin', () => io.scrollMargin);
  call('io.thresholds', () => io.thresholds);
  call('io.thresholds[0]', () => io.thresholds[0]);
  call('io.delay', () => io.delay);
  call('io.trackVisibility', () => io.trackVisibility);
  const io2 = new IntersectionObserver(() => {}, {
    root: document.body, rootMargin: '10px 20px', threshold: [0.25, 0.75], delay: 100, trackVisibility: true,
  });
  call('io2.root', () => io2.root === document.body);
  call('io2.rootMargin', () => io2.rootMargin);
  call('io2.thresholds', () => io2.thresholds.join(','));
  call('io2.delay', () => io2.delay);
  call('io2.trackVisibility', () => io2.trackVisibility);
  call('io3.rootMargin single', () => new IntersectionObserver(() => {}, { rootMargin: '5px' }).rootMargin);

  const face = new FontFace('F', 'url(/f.woff2)');
  for (const n of ['ascentOverride', 'descentOverride', 'lineGapOverride', 'sizeAdjust', 'variationSettings']) {
    call('face.' + n, () => face[n]);
    call('face.' + n + ' = set', () => { face[n] = n === 'sizeAdjust' ? '50%' : 'normal'; return face[n]; });
  }
  call('face with descriptors', () => new FontFace('F', 'url(/f.woff2)', {
    ascentOverride: '90%', sizeAdjust: '80%', variationSettings: '"wght" 700',
  }).ascentOverride);

  const selection = getSelection();
  const node = document.createElement('p');
  node.textContent = 'hello';
  document.body.appendChild(node);
  selection.setBaseAndExtent(node.firstChild, 1, node.firstChild, 3);
  call('selection.baseNode', () => selection.baseNode === node.firstChild);
  call('selection.baseOffset', () => selection.baseOffset);
  call('selection.extentNode', () => selection.extentNode === node.firstChild);
  call('selection.extentOffset', () => selection.extentOffset);
  call('selection.getComposedRanges()', () => selection.getComposedRanges());
  call('selection.getComposedRanges().length', () => selection.getComposedRanges().length);
  call('selection.getComposedRanges()[0]', () => selection.getComposedRanges()[0]);
  call('selection.getComposedRanges({}) ', () => selection.getComposedRanges({ shadowRoots: [] }).length);
  selection.removeAllRanges();
  call('empty selection.baseNode', () => selection.baseNode);
  call('empty selection.baseOffset', () => selection.baseOffset);
  call('empty getComposedRanges().length', () => selection.getComposedRanges().length);
  node.remove();

  call('navigation.onnavigate', () => navigation.onnavigate);
  call('navigation.onnavigate set', () => { navigation.onnavigate = () => {}; return typeof navigation.onnavigate; });
  call('navigation.onnavigatesuccess', () => navigation.onnavigatesuccess);
  call('navigation.onnavigateerror', () => navigation.onnavigateerror);
  call('navigation.reload arity', () => Navigation.prototype.reload.length);

  const doctype = document.doctype;
  call('doctype', () => doctype);
  call('doctype.after arity', () => DocumentType.prototype.after.length);
  call('doctype.before arity', () => DocumentType.prototype.before.length);
  call('doctype.replaceWith arity', () => DocumentType.prototype.replaceWith.length);

  const attrs = document.body.attributes;
  call('attrs.getNamedItemNS(null, id)', () => attrs.getNamedItemNS(null, 'id'));
  document.body.setAttribute('data-x', '1');
  call('attrs.getNamedItemNS(null, data-x)', () => attrs.getNamedItemNS(null, 'data-x')?.value);
  call('attrs.getNamedItemNS(ns, data-x)', () => attrs.getNamedItemNS('urn:x', 'data-x'));
  call('attrs.removeNamedItemNS(null, data-x)', () => attrs.removeNamedItemNS(null, 'data-x')?.value);
  call('attrs.removeNamedItemNS(null, gone)', () => attrs.removeNamedItemNS(null, 'gone'));
  call('attrs.setNamedItemNS', () => {
    const a = document.createAttribute('data-y');
    a.value = '2';
    const prior = attrs.setNamedItemNS(a);
    return [describe(prior), document.body.getAttribute('data-y')].join('|');
  });
  document.body.removeAttribute('data-y');

  call('visualViewport.onresize', () => visualViewport.onresize);
  call('visualViewport.onresize set', () => { visualViewport.onresize = () => {}; return typeof visualViewport.onresize; });
  call('visualViewport.onscroll', () => visualViewport.onscroll);
  call('visualViewport.onscrollend', () => visualViewport.onscrollend);

  class Widget extends HTMLElement {}
  customElements.define('x-widget-probe', Widget);
  call('customElements.getName(Widget)', () => customElements.getName(Widget));
  call('customElements.getName(unknown)', () => customElements.getName(class extends HTMLElement {}));
  call('customElements.getName arity', () => CustomElementRegistry.prototype.getName.length);
  call('customElements.initialize(root)', () => customElements.initialize(document.createElement('div')));
  call('customElements.initialize arity', () => CustomElementRegistry.prototype.initialize.length);

  const matrix = new DOMMatrixReadOnly([1, 2, 3, 4, 5, 6]);
  call('matrix.toJSON()', () => matrix.toJSON());
  call('matrix.toJSON() keys', () => Object.keys(matrix.toJSON()).join(','));
  call('matrix.toJSON().a', () => matrix.toJSON().a);
  call('matrix.toJSON().is2D', () => matrix.toJSON().is2D);
  call('matrix.transformPoint()', () => matrix.transformPoint());
  call('matrix.transformPoint().x', () => matrix.transformPoint().x);
  call('matrix.transformPoint({x:1,y:1}).x', () => matrix.transformPoint({ x: 1, y: 1 }).x);
  call('matrix.transformPoint({x:1,y:1}).y', () => matrix.transformPoint({ x: 1, y: 1 }).y);
  call('matrix.transformPoint({x:1,y:1}).w', () => matrix.transformPoint({ x: 1, y: 1 }).w);
  call('matrix.transformPoint arity', () => DOMMatrixReadOnly.prototype.transformPoint.length);

  call('IDBVersionChangeEvent dataLoss', () => new IDBVersionChangeEvent('v').dataLoss);
  call('IDBVersionChangeEvent dataLossMessage', () => new IDBVersionChangeEvent('v').dataLossMessage);

  call('EventTarget.when arity', () => EventTarget.prototype.when.length);
  call('EventTarget.when result', () => new EventTarget().when('x'));
  call('Date.toTemporalInstant', () => new Date(0).toTemporalInstant());
  call('Date.toTemporalInstant epoch', () => String(new Date(0).toTemporalInstant()));
  call('Temporal global', () => self.Temporal);

  return JSON.stringify(out);
})()
