// The whole surface a dedicated blob worker sees, read from inside the worker --
// and the same reading taken in the page that built it, so a worker-realm
// difference can be told from a difference this engine has everywhere.
//
// The station this fork is measured against runs its probes inside blob workers
// (they are `eval` trampolines: the page posts source in, the worker runs it).
// Whatever it posts runs against *this* realm's globals, not the page's, and
// every surface reading in this directory so far was taken in a Window realm.
//
// Output is deliberately mechanical: names, kinds, arities and a short list of
// values, once per realm. Diff the two arms and the diff is the answer.
(async () => {
    const READER = `(() => {
      const g = typeof self !== 'undefined' ? self : globalThis;
      const kindOf = (o, n) => {
        const d = Object.getOwnPropertyDescriptor(o, n);
        if (!d) return 'missing';
        let k;
        if (d.get || d.set) k = 'accessor' + (d.get ? '/get' : '') + (d.set ? '/set' : '');
        else if (typeof d.value === 'function') k = 'function/' + d.value.length;
        else k = typeof d.value;
        return k + (d.enumerable ? ' e' : '') + (d.configurable ? ' c' : '') + (d.writable ? ' w' : '');
      };

      const chain = [];
      for (let o = g, i = 0; o; o = Object.getPrototypeOf(o), i++) {
        const c = Object.getOwnPropertyDescriptor(o, 'constructor');
        chain.push({
          level: i === 0 ? 'self'
               : (c && typeof c.value === 'function' ? c.value.name : '<anonymous>') + '.prototype',
          names: Object.getOwnPropertyNames(o).sort(),
        });
      }

      const selfNames = Object.getOwnPropertyNames(g).sort();
      const kinds = {};
      for (const n of selfNames) kinds[n] = kindOf(g, n);

      // Constructor shape for every own global that is a function: the name it
      // answers with, its arity, and how many members its prototype carries.
      const ctors = {};
      for (const n of selfNames) {
        let v;
        try { v = g[n]; } catch (e) { ctors[n] = 'threw: ' + String(e).slice(0, 60); continue; }
        if (typeof v !== 'function') continue;
        let protoCount = null;
        try { protoCount = v.prototype ? Object.getOwnPropertyNames(v.prototype).length : null; } catch (e) {}
        ctors[n] = { name: v.name, length: v.length, proto_own: protoCount };
      }

      const surfaceOf = (obj) => {
        const out = {};
        if (!obj) return null;
        for (let o = obj; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) {
          for (const n of Object.getOwnPropertyNames(o)) {
            if (n === 'constructor' || n in out) continue;
            out[n] = kindOf(o, n);
          }
        }
        return out;
      };
      const valuesOf = (obj, keys) => {
        const out = {};
        for (const k of keys) {
          try {
            const v = obj[k];
            out[k] = typeof v === 'object' && v !== null ? JSON.parse(JSON.stringify(v)) : v;
          } catch (e) { out[k] = 'threw: ' + String(e).slice(0, 60); }
        }
        return out;
      };

      // The clamp a timing check reads off a busy loop, not a claim about it.
      let clamp = null;
      {
        let best = Infinity;
        let prev = performance.now();
        for (let i = 0; i < 5000; i++) {
          const t = performance.now();
          if (t > prev && t - prev < best) best = t - prev;
          prev = t;
        }
        clamp = best === Infinity ? null : best;
      }

      const values = {
        location: valuesOf(location, ['href', 'origin', 'protocol', 'host', 'hostname',
                                      'port', 'pathname', 'search', 'hash']),
        location_string: String(location),
        origin: g.origin,
        isSecureContext: g.isSecureContext,
        crossOriginIsolated: g.crossOriginIsolated,
        self_name: g.name,
        navigator_values: valuesOf(navigator, ['userAgent', 'appVersion', 'appName',
          'appCodeName', 'platform', 'product', 'language', 'languages', 'onLine',
          'hardwareConcurrency', 'deviceMemory', 'webdriver', 'vendor', 'vendorSub',
          'productSub', 'doNotTrack']),
        navigator_ctor_name: (() => {
          try { return navigator.constructor.name; } catch (e) { return 'threw'; }
        })(),
        userAgentData: (() => {
          try {
            const u = navigator.userAgentData;
            if (!u) return String(u);
            return { brands: u.brands, mobile: u.mobile, platform: u.platform };
          } catch (e) { return 'threw: ' + String(e).slice(0, 60); }
        })(),
        clock_clamp: clamp,
        performance_now_typeof: typeof performance.now(),
        timeOrigin_typeof: typeof performance.timeOrigin,
        toString_self: Object.prototype.toString.call(g),
        toString_navigator: Object.prototype.toString.call(navigator),
        toString_location: Object.prototype.toString.call(location),
        self_is_globalThis: g === globalThis,
      };

      const surfaces = {
        navigator: surfaceOf(navigator),
        location: surfaceOf(location),
        performance: surfaceOf(performance),
      };

      return { chain, kinds, ctors, values, surfaces };
    })()`;

    const src = `postMessage(${READER});`;
    const url = URL.createObjectURL(new Blob([src], { type: 'text/javascript' }));
    const w = new Worker(url);
    const worker = await new Promise((resolve, reject) => {
        w.onmessage = (e) => resolve(e.data);
        w.onerror = (e) => reject(new Error('worker error: ' + (e.message || e.type)));
        setTimeout(() => reject(new Error('worker timeout')), 8000);
    });
    // eslint-disable-next-line no-eval
    const window_realm = (0, eval)(READER);
    return { worker, window: window_realm };
})()
