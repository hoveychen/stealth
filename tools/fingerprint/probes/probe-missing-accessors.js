// The 97 accessors probe-descriptor-kind found on Chrome's prototypes and not on
// this engine's -- read for what they actually answer, so the decision to add or
// skip each one is made against a measurement rather than against IDL from
// memory.
//
// Three things per property, because they are what separate the categories:
//   * `value` -- what a fresh instance answers, and its type. A property whose
//     honest answer here is `null`, `0` or `""` costs nothing to add.
//   * `reflects` -- for a settable one, which content attribute the assignment
//     moved. A reflected attribute is a self-contained getter/setter pair; a
//     property whose assignment lands nowhere visible needs real state.
//   * `interface` -- the Symbol.toStringTag of a non-primitive answer. This is
//     the one that says "adding this means adding a whole interface", which is
//     the only real reason to skip.
//
//   node tools/fingerprint/run-probe.mjs chrome probes/probe-missing-accessors.js \
//       http://localhost:8777/ --headed
//
// Reading in results/probes/probe-missing-accessors.chrome.json.
(async () => {
  const describe = (v) => {
    if (v === null) return { value: 'null', type: 'null' };
    if (v === undefined) return { value: 'undefined', type: 'undefined' };
    const t = typeof v;
    if (t === 'object' || t === 'function') {
      const tag = Object.prototype.toString.call(v).slice(8, -1);
      let extra = '';
      if (Array.isArray(v)) extra = ' len=' + v.length;
      else if (typeof v.length === 'number') extra = ' len=' + v.length;
      else if (v instanceof Date) extra = ' ' + v.toISOString();
      return { value: tag + extra, type: t, interface: tag };
    }
    // JSON.stringify(NaN) is "null", which would archive `valueAsNumber` as a
    // null rather than the NaN it is -- and send the next reader to implement
    // the wrong thing.
    if (t === 'number' && !Number.isFinite(v)) return { value: String(v), type: t };
    return { value: JSON.stringify(v), type: t };
  };

  // Which content attribute, if any, an assignment moved. Snapshot the whole
  // attribute set before and after so a reflection under a different name than
  // the property is still caught.
  const reflection = (el, key, probe_value) => {
    if (!el || !el.attributes) return undefined;
    const before = {};
    for (const a of el.attributes) before[a.name] = a.value;
    let threw = null;
    try {
      el[key] = probe_value;
    } catch (e) {
      threw = e.constructor.name + ': ' + e.message;
    }
    const moved = [];
    for (const a of el.attributes) {
      if (before[a.name] !== a.value) moved.push(a.name + '=' + JSON.stringify(a.value));
    }
    for (const name of Object.keys(before)) {
      if (!el.hasAttribute(name)) moved.push('-' + name);
    }
    const out = { after_read: describe(el[key]).value };
    if (moved.length) out.reflects = moved.join(' ');
    if (threw) out.threw = threw;
    return out;
  };

  const out = {};
  const read = (iface, instance, keys, opts) => {
    const per = {};
    for (const key of keys) {
      const d = Object.getOwnPropertyDescriptor(window[iface] && window[iface].prototype, key);
      const row = { kind: !d ? 'ABSENT-IN-CHROME' : (d.get && d.set ? 'accessor' : d.get ? 'get' : 'set') };
      try {
        Object.assign(row, describe(d.get.call(instance)));
      } catch (e) {
        row.value = 'THREW ' + e.constructor.name + ': ' + e.message;
      }
      if (d && d.set && opts && opts.element) {
        Object.assign(row, reflection(instance, key, opts.probe === undefined ? 'probe-value' : opts.probe));
      }
      per[key] = row;
    }
    out[iface] = per;
  };

  const div = document.createElement('div');
  read('Element', div, ['ariaActionsElements']);

  read('HTMLIFrameElement', document.createElement('iframe'), [
    'csp', 'allow', 'featurePolicy', 'loading', 'credentialless',
    'allowPaymentRequest', 'privateToken', 'browsingTopics', 'adAuctionHeaders',
    'sharedStorageWritable',
  ], { element: true });

  read('HTMLScriptElement', document.createElement('script'), [
    'referrerPolicy', 'fetchPriority', 'blocking', 'textContent', 'attributionSrc',
  ], { element: true });

  read('HTMLInputElement', document.createElement('input'), [
    'height', 'valueAsDate', 'valueAsNumber', 'width', 'webkitdirectory',
    'incremental', 'webkitEntries',
  ], { element: true });

  // relList before rel: they are the same attribute, and reading the list after
  // assigning the string would archive the assignment as the default.
  read('HTMLFormElement', document.createElement('form'), ['relList', 'rel'], { element: true });

  read('HTMLImageElement', document.createElement('img'), [
    'sizes', 'fetchPriority', 'x', 'y', 'browsingTopics', 'attributionSrc',
    'sharedStorageWritable',
  ], { element: true });

  read('HTMLAnchorElement', document.createElement('a'), [
    'interestForElement', 'hrefTranslate', 'attributionSrc',
  ], { element: true });

  read('MouseEvent', new MouseEvent('click'), ['movementX', 'movementY', 'fromElement', 'toElement']);
  read('PointerEvent', new PointerEvent('pointerdown'), ['persistentDeviceId']);
  read('UIEvent', new UIEvent('x'), ['pseudoTarget']);
  read('MessageEvent', new MessageEvent('message'), ['userActivation']);

  // The six init options an IntersectionObserver reads back. Constructed with
  // non-defaults so a wrong default here would be visible.
  read('IntersectionObserver', new IntersectionObserver(() => {}, {
    rootMargin: '10px 20px', threshold: [0, 0.5, 1],
  }), ['root', 'rootMargin', 'scrollMargin', 'thresholds', 'delay', 'trackVisibility']);

  read('PerformanceEntry', performance.getEntries()[0], ['navigationId']);

  const host = document.createElement('div');
  document.body.appendChild(host);
  read('ShadowRoot', host.attachShadow({ mode: 'open' }), [
    'innerHTML', 'styleSheets', 'pointerLockElement', 'fullscreenElement',
    'pictureInPictureElement', 'customElementRegistry',
  ]);

  read('Selection', getSelection(), ['baseNode', 'baseOffset', 'extentNode', 'extentOffset']);

  div.setAttribute('data-x', '1');
  read('Attr', div.attributes[0], ['prefix', 'specified']);

  read('Request', new Request('/probe'), [
    'destination', 'referrer', 'referrerPolicy', 'mode', 'integrity', 'keepalive',
    'duplex', 'isHistoryNavigation', 'targetAddressSpace', 'isReloadNavigation',
  ]);

  read('File', new File(['hi'], 'a.txt'), ['lastModifiedDate', 'webkitRelativePath']);

  read('VisualViewport', window.visualViewport, ['onresize', 'onscroll', 'onscrollend']);
  read('ScreenOrientation', screen.orientation, ['onchange']);

  // Notification's constructor is gated on permission; record whatever it does.
  let notification = null;
  try {
    notification = new Notification('probe');
  } catch (e) {
    out['Notification_construct'] = e.constructor.name + ': ' + e.message;
  }
  read('Notification', notification, [
    'onclick', 'onshow', 'onerror', 'onclose', 'vibrate', 'timestamp', 'data', 'actions',
  ]);

  read('FontFace', new FontFace('T', 'local(Arial)'), [
    'ascentOverride', 'descentOverride', 'lineGapOverride', 'sizeAdjust', 'variationSettings',
  ]);
  read('FontFaceSet', document.fonts, ['onloading', 'onloadingdone', 'onloadingerror']);

  const internals_name = 'probe-internals-' + Object.keys(out).length;
  customElements.define(internals_name, class extends HTMLElement {
    constructor() {
      super();
      this._internals = this.attachInternals();
    }
  });
  read('ElementInternals', document.createElement(internals_name)._internals, ['ariaActionsElements']);

  out['IDBDatabase'] = await new Promise((resolve) => {
    const req = indexedDB.open('probe-missing-accessors', 1);
    req.onupgradeneeded = (e) => e.target.result.createObjectStore('s');
    req.onsuccess = (e) => {
      const db = e.target.result;
      const per = {};
      for (const key of ['onabort', 'onclose', 'onversionchange']) {
        const d = Object.getOwnPropertyDescriptor(IDBDatabase.prototype, key);
        per[key] = { kind: d.get && d.set ? 'accessor' : 'get', ...describe(d.get.call(db)) };
      }
      db.close();
      resolve(per);
    };
    req.onerror = () => resolve({ error: 'open failed' });
  });

  return { href: location.href, out };
})()
