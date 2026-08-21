// The one realm boundary no other probe in this directory crosses: what a page
// can read off a *cross-origin* iframe's `contentWindow` and its `location`.
//
// Why here and not the main realm. Turnstile's failure on the Cloudflare
// interstitial is a TypeError -- "Cannot read properties of undefined (reading
// 'call')" -- and the sweep's wire log puts it immediately after the widget's
// own document arrives, with no request ever coming *from* that document:
//
//   res 200  .../turnstile/f/av0/rch/<id>/.../new/normal        Document
//   console.error  [Cloudflare Turnstile] Unhandled error: TypeError: ...
//   console.warning [Cloudflare Turnstile] Cannot find Widget cf-chl-widget-<id>
//
// That widget document is served from challenges.cloudflare.com while the page is
// the site's own origin, so the object api.js holds is the cross-origin window
// proxy. WebIDL safelists a short set of properties on it (`window`, `self`,
// `location`, `close`, `closed`, `focus`, `blur`, `frames`, `length`, `top`,
// `opener`, `parent`, `postMessage`) plus a CrossOriginLocation carrying `href`
// and `replace`; everything else must throw a SecurityError on access. Both
// halves of that are fingerprintable and neither is measured anywhere else:
// probe-descriptor-kind and probe-globals both read the top-level realm only,
// which the README's own caveat flags as the gap.
//
// Reads each name three ways, because "missing" and "throws" are different
// answers and only one of them is Chrome's: whether `in` sees it, what `typeof`
// says, and whether touching it throws. A name that answers `undefined` where
// Chrome throws SecurityError is as much a tell as one that is absent where
// Chrome has it.
//
//   node tools/fingerprint/run-probe.mjs chrome probes/probe-cross-origin-surface.js \
//       http://localhost:8777/ --headed
//   node tools/fingerprint/run-page-probe.mjs probes/probe-cross-origin-surface.js
//
// The second one is not run-probe: this probe waits for a load event, and this
// engine does not run scheduled tasks while a Runtime.evaluate with awaitPromise
// is outstanding, so it hangs there. Chrome handles both.
//
// Readings in results/probes/probe-cross-origin-surface.{chrome,lightpanda}.json.
(async () => {
  // The WebIDL cross-origin safelist, then names that must NOT come through --
  // the ones a same-origin window has and a cross-origin proxy has to deny.
  const SAFELISTED = [
    'window', 'self', 'location', 'close', 'closed', 'focus', 'blur', 'frames',
    'length', 'top', 'opener', 'parent', 'postMessage',
  ];
  const MUST_DENY = [
    'document', 'navigator', 'localStorage', 'sessionStorage', 'name', 'origin',
    'history', 'screen', 'performance', 'innerWidth', 'innerHeight', 'devicePixelRatio',
    'alert', 'fetch', 'addEventListener', 'getComputedStyle', 'isSecureContext',
    'crypto', 'indexedDB', 'caches', 'onload', 'onerror', 'eval', 'Function',
  ];
  const LOCATION_PROPS = [
    'href', 'replace', 'ancestorOrigins', 'protocol', 'host', 'hostname', 'port',
    'pathname', 'search', 'hash', 'origin', 'assign', 'reload', 'toString',
  ];

  // Three separate questions per name. `in` on a cross-origin proxy is itself a
  // guarded operation, so it gets its own try.
  const read = (obj, key) => {
    const r = {};
    try { r.in = key in obj; } catch (e) { r.in = 'THREW ' + e.name; }
    try { r.type = typeof obj[key]; } catch (e) { r.type = 'THREW ' + e.name; }
    try {
      const d = Object.getOwnPropertyDescriptor(obj, key);
      r.desc = d ? (d.get ? (d.set ? 'accessor' : 'get') : (typeof d.value === 'function' ? 'method' : 'value')) : 'absent';
    } catch (e) { r.desc = 'THREW ' + e.name; }
    return r;
  };

  const names = (obj) => {
    try { return Object.getOwnPropertyNames(obj).join(' '); } catch (e) { return 'THREW ' + e.name; }
  };
  const tag = (v) => { try { return Object.prototype.toString.call(v); } catch (e) { return 'THREW ' + e.name; } };

  // This has to wait for the navigation to commit, which is the trap a first
  // attempt fell into: read synchronously after appendChild and the frame is
  // still on its initial about:blank, which is *same-origin*. Chrome then hands
  // back the full window -- 900-odd own names -- and the two engines end up
  // answering different questions. So: wait for the load event, and carry a
  // same-origin about:blank frame alongside as the control that says whether the
  // boundary was actually crossed.
  //
  // Because it awaits, run it through run-page-probe.mjs for this engine
  // (Runtime.evaluate with awaitPromise does not run scheduled tasks here) and
  // run-probe.mjs for Chrome.
  const attach = (src) => new Promise((resolve) => {
    const f = document.createElement('iframe');
    let settled = false;
    const go = (how) => { if (!settled) { settled = true; resolve({ f, how }); } };
    f.addEventListener('load', () => go('load'));
    setTimeout(() => go('timeout'), 6000);
    f.src = src;
    document.documentElement.appendChild(f);
  });

  const cross = await attach('https://example.com/');
  const same = await attach('about:blank');
  const w = cross.f.contentWindow;
  const out = {
    committedBy: cross.how,
    // The control: a same-origin frame read the same way. `document` must be
    // reachable here and denied on the cross-origin one; if both answer alike,
    // the reading below is not measuring a boundary at all.
    sameOrigin: (() => {
      const sw = same.f.contentWindow;
      const r = { how: same.how };
      try { r.document = typeof sw.document; } catch (e) { r.document = 'THREW ' + e.name; }
      try { r.ownNameCount = Object.getOwnPropertyNames(sw).length; } catch (e) { r.ownNameCount = 'THREW ' + e.name; }
      try { r.location = typeof sw.location; } catch (e) { r.location = 'THREW ' + e.name; }
      return r;
    })(),
    proxy: {
      tag: tag(w),
      ownNames: names(w),
      ownSymbols: (() => { try { return Object.getOwnPropertySymbols(w).map(String).join(' '); } catch (e) { return 'THREW ' + e.name; } })(),
      proto: (() => { try { return String(Object.getPrototypeOf(w)); } catch (e) { return 'THREW ' + e.name; } })(),
      isFrozen: (() => { try { return Object.isFrozen(w); } catch (e) { return 'THREW ' + e.name; } })(),
      // Why the brand reads the way it does. Chrome answers '[object Object]'
      // here, and the reason is in this descriptor rather than in the class: the
      // proxy *has* an own Symbol.toStringTag whose value is not a string, so
      // Object.prototype.toString falls all the way back to 'Object'.
      toStringTagDesc: (() => {
        try {
          const d = Object.getOwnPropertyDescriptor(w, Symbol.toStringTag);
          if (!d) return 'absent';
          return { value: String(d.value), valueType: typeof d.value, get: !!d.get, writable: !!d.writable, enumerable: !!d.enumerable, configurable: !!d.configurable };
        } catch (e) { return 'THREW ' + e.name; }
      })(),
      hasInstanceDesc: (() => {
        try {
          const d = Object.getOwnPropertyDescriptor(w, Symbol.hasInstance);
          return d ? { valueType: typeof d.value, get: !!d.get } : 'absent';
        } catch (e) { return 'THREW ' + e.name; }
      })(),
      // `then` is on the safelist Chrome ships and is not in the WebIDL list;
      // it exists so awaiting a cross-origin window does not hang.
      then: (() => { try { return typeof w.then; } catch (e) { return 'THREW ' + e.name; } })(),
    },
    safelisted: {},
    mustDeny: {},
    location: { tag: null, ownNames: null, props: {} },
  };
  for (const k of SAFELISTED) out.safelisted[k] = read(w, k);
  for (const k of MUST_DENY) out.mustDeny[k] = read(w, k);

  let loc = null;
  try { loc = w.location; } catch (e) { out.location.tag = 'THREW ' + e.name; }
  if (loc != null) {
    out.location.tag = tag(loc);
    out.location.ownNames = names(loc);
    for (const k of LOCATION_PROPS) out.location.props[k] = read(loc, k);
  } else if (out.location.tag === null) {
    out.location.tag = 'undefined';
  }

  // The two-level read that produces "reading 'call'": `X.y.call(...)` throws
  // that exact message when `X.y` is undefined but `X` is not. Recorded as the
  // shape of the expression rather than its result, so both engines answer the
  // same question and a THREW line names which level went missing.
  const twoLevel = {
    'w.postMessage.call': () => typeof w.postMessage.call,
    'w.location.replace.call': () => typeof w.location.replace.call,
    'w.location.href': () => typeof w.location.href,
    'w.close.call': () => typeof w.close.call,
    'w.focus.call': () => typeof w.focus.call,
    'w.blur.call': () => typeof w.blur.call,
  };
  out.twoLevel = {};
  for (const [label, fn] of Object.entries(twoLevel)) {
    try { out.twoLevel[label] = fn(); } catch (e) { out.twoLevel[label] = 'THREW ' + e.name + ': ' + e.message; }
  }

  // The hypothesis this probe exists to test. Turnstile dies on the interstitial
  // with "Cannot read properties of undefined (reading 'call')" right after the
  // cross-origin widget frame arrives. Reading a *denied* name off the proxy is
  // a SecurityError in Chrome -- a throw the widget is written to expect -- and
  // an undefined here, because this engine's proxy answers undefined for
  // everything off the safelist instead of throwing. `undefined.call` then
  // raises exactly that TypeError, which nothing is written to expect.
  //
  // So the same source line produces a handled SecurityError there and an
  // unhandled TypeError here, and the message names 'call' rather than the
  // property because the denial happened one level up.
  out.deniedThenCall = {};
  for (const k of ['document', 'eval', 'addEventListener', 'getComputedStyle', 'navigator']) {
    try {
      const v = w[k].call;
      out.deniedThenCall['w.' + k + '.call'] = typeof v;
    } catch (e) {
      out.deniedThenCall['w.' + k + '.call'] = e.name + ': ' + e.message;
    }
  }
  return { href: location.href, out };
})()
