// The reporting family probe-shapes.js found on the window and this engine did
// not have: ReportBody and its two subclasses, the two bfcache
// not-restored-reason objects, and CrashReportContext.
//
// Five of the six are unreachable -- Illegal constructor, and only the browser's
// own report queue or a bfcache miss produces an instance -- so the prototype is
// the whole surface. The sixth is the exception and the reason this probe exists:
// `window.crashReport` IS a live CrashReportContext, so what its three methods
// answer is measurable, and they answer three different DOMExceptions depending
// on whether initialize() has resolved yet.
//
//   python3 -m http.server 8777 --bind 0.0.0.0   # in an empty directory
//   node tools/fingerprint/run-probe.mjs chrome probes/probe-s3-reporting.js \
//       http://localhost:8777/ --headed
//
// Recorded that way off a headed Chrome 151 in
// results/probes/probe-s3-reporting.chrome.json.
(async () => {
  const S = (fn) => {
    try {
      const v = fn();
      if (v === undefined) return 'undefined';
      if (v === null) return 'null';
      return typeof v === 'object' ? Object.prototype.toString.call(v) : v;
    } catch (e) { return `${e.name}: ${e.message}`; }
  };
  const A = async (fn) => {
    try { const v = await fn(); return v === undefined ? 'resolved:undefined' : `resolved:${v}`; }
    catch (e) { return `rejected:${e.name}: ${e.message}`; }
  };

  const out = {};

  // Every getter on the five unreachable prototypes, read off the prototype
  // itself -- the one thing a page can still try.
  out.protoReads = {};
  for (const name of ['ReportBody', 'CSPViolationReportBody', 'IntegrityViolationReportBody',
    'NotRestoredReasons', 'NotRestoredReasonDetails']) {
    const proto = window[name].prototype;
    const per = {};
    for (const key of Object.getOwnPropertyNames(proto)) {
      if (key === 'constructor') continue;
      per[key] = S(() => {
        const d = Object.getOwnPropertyDescriptor(proto, key);
        return d.get ? d.get.call(proto) : d.value.call(proto);
      });
    }
    out.protoReads[name] = per;
  }

  // window.crashReport: the descriptor, the identity, and what the object looks
  // like as data.
  const c = window.crashReport;
  const desc = Object.getOwnPropertyDescriptor(window, 'crashReport');
  out.crashReportDescriptor = {
    get: typeof desc.get, set: typeof desc.set,
    enumerable: desc.enumerable, configurable: desc.configurable,
  };
  out.crashReportStableIdentity = window.crashReport === window.crashReport;
  out.crashReportBrand = Object.prototype.toString.call(c);
  out.crashReportOwnKeys = Object.keys(c);
  out.crashReportJson = S(() => JSON.stringify(c));
  out.crashReportPerRealm = S(() => {
    const f = document.createElement('iframe');
    document.body.appendChild(f);
    const same = f.contentWindow.crashReport === c;
    const brand = Object.prototype.toString.call(f.contentWindow.crashReport);
    f.remove();
    return `same=${same} brand=${brand}`;
  });

  // Before initialize(): set and delete refuse with an InvalidStateError, and
  // too few arguments is a plain TypeError ahead of that.
  out.beforeInitialize = {
    setNoArgs: S(() => c.set()),
    setOneArg: S(() => c.set('a')),
    setTwoArgs: S(() => c.set('a', 'b')),
    deleteNoArgs: S(() => c.delete()),
    deleteKey: S(() => c.delete('a')),
  };

  // initialize() is the only one that answers a promise, and the argument-count
  // failure comes back as a *rejection* rather than a synchronous throw.
  out.initializeNoArgs = await A(() => c.initialize());
  out.initializeObject = await A(() => c.initialize({ k: 'v' }));
  // A second call, whatever it is handed: the already-called check comes after
  // the count check and before anything looks at the value.
  out.initializeAgain = await A(() => c.initialize({ k: 'v' }));
  out.initializeAgainNonObject = await A(() => c.initialize(5));

  // The gate is the argument *count*, not its type: on a fresh context (a
  // same-origin iframe gets its own) every one of these resolves, including an
  // explicit undefined -- while passing nothing at all rejects above.
  out.freshInitialize = {};
  for (const [label, arg] of [['number', 5], ['string', 'x'], ['null', null],
    ['undefinedExplicit', undefined], ['emptyObject', {}], ['array', []]]) {
    const frame = document.createElement('iframe');
    await new Promise((r) => { frame.onload = r; document.body.appendChild(frame); });
    out.freshInitialize[label] = await A(() => frame.contentWindow.crashReport.initialize(arg));
    frame.remove();
  }

  // After it has resolved: a different DOMException, because this page has no
  // crash-report buffer to write into.
  out.afterInitialize = {
    setTwoArgs: S(() => c.set('a', 'b')),
    setEmptyKey: S(() => c.set('', 'v')),
    setNonString: S(() => c.set(1, 2)),
    deleteKey: S(() => c.delete('a')),
    ownKeys: Object.keys(c),
    json: S(() => JSON.stringify(c)),
  };

  return { href: location.href, isSecureContext: window.isSecureContext, out };
})()
