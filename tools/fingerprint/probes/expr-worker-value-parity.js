// The same readings taken in three realms of one page: the window, a dedicated
// blob worker, and a SharedWorker built from the same blob.
//
// The engine's own `prop_read` log (`prop-reads.mjs`) against the macys
// interstitial says the collector reads seven `WorkerNavigator` members, the
// worker's `userAgentData`, and an `OffscreenCanvas` WebGL context *inside two
// SharedWorkers*, then reads the same members again in the window. A collector
// that reads a value on both sides of a realm boundary is comparing them, and
// `prop-reads-diff.mjs` cannot follow it there: every member on that list needs
// a receiver, so all 29 of them were dropped from the singleton probe.
//
// So take the reading in all three realms and print it three times. Two diffs
// come out of one run: page-vs-worker within an arm (a parity the station can
// check without a second browser to compare against), and arm-vs-arm per realm.
(async () => {
    const READER = `(async () => {
      const g = typeof self !== 'undefined' ? self : globalThis;
      const n = g.navigator;
      const out = {
        realm: Object.prototype.toString.call(g),
        userAgent: n && n.userAgent,
        appVersion: n && n.appVersion,
        appCodeName: n && n.appCodeName,
        platform: n && n.platform,
        product: n && n.product,
        productSub: n && n.productSub,
        vendor: n && n.vendor,
        language: n && n.language,
        languages: n && n.languages && Array.from(n.languages).join(','),
        hardwareConcurrency: n && n.hardwareConcurrency,
        deviceMemory: n && n.deviceMemory,
        onLine: n && n.onLine,
        webdriver: n && 'webdriver' in n ? n.webdriver : 'absent',
        uaData: 'absent',
        highEntropy: 'absent',
        offscreen: typeof g.OffscreenCanvas,
      };
      if (n && n.userAgentData) {
        out.uaData = JSON.stringify(n.userAgentData.toJSON());
        try {
          out.highEntropy = JSON.stringify(await n.userAgentData.getHighEntropyValues(
            ['architecture', 'bitness', 'model', 'platformVersion', 'uaFullVersion', 'fullVersionList', 'wow64', 'formFactors']));
        } catch (e) { out.highEntropy = 'throw: ' + (e && e.message); }
      }
      // What the station's worker probe actually asks the GPU for, in the order
      // it asks: the debug extension first, then a handful of strings.
      for (const kind of ['webgl', 'webgl2']) {
        const rec = {};
        try {
          const c = typeof g.OffscreenCanvas === 'function' ? new g.OffscreenCanvas(256, 256)
            : g.document.createElement('canvas');
          const gl = c.getContext(kind);
          if (!gl) { out[kind] = 'null-context'; continue; }
          const dbg = gl.getExtension('WEBGL_debug_renderer_info');
          rec.debugExt = dbg ? 'present' : String(dbg);
          if (dbg) {
            rec.unmaskedVendor = gl.getParameter(dbg.UNMASKED_VENDOR_WEBGL);
            rec.unmaskedRenderer = gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL);
          }
          rec.vendor = gl.getParameter(gl.VENDOR);
          rec.renderer = gl.getParameter(gl.RENDERER);
          rec.version = gl.getParameter(gl.VERSION);
          rec.shading = gl.getParameter(gl.SHADING_LANGUAGE_VERSION);
          rec.maxTexture = gl.getParameter(gl.MAX_TEXTURE_SIZE);
          rec.extensions = (gl.getSupportedExtensions() || []).length;
          out[kind] = JSON.stringify(rec);
        } catch (e) { out[kind] = 'throw: ' + (e && e.message); }
      }
      return out;
    })()`;

    const result = { page: null, dedicated: null, shared: null };
    result.page = await eval(READER);

    // The station's own shape: post source into the worker and let it answer.
    // Both worker kinds get the same trampoline so the only difference between
    // the two readings is the global they run against.
    const src = `self.__run = (s, reply) => Promise.resolve(eval(s)).then(reply, (e) => reply({ error: String(e && e.message || e) }));
      if (typeof onconnect !== 'undefined' || 'SharedWorkerGlobalScope' in self) {
        self.onconnect = (e) => { const p = e.ports[0]; p.start(); p.onmessage = (m) => self.__run(m.data, (v) => p.postMessage(v)); };
      }
      self.onmessage = (m) => self.__run(m.data, (v) => self.postMessage(v));`;
    const url = URL.createObjectURL(new Blob([src], { type: 'text/javascript' }));

    const ask = (post, on) => new Promise((resolve) => {
        const timer = setTimeout(() => resolve({ error: 'no reply in 8000ms' }), 8000);
        on((v) => { clearTimeout(timer); resolve(v); });
        post();
    });

    try {
        const w = new Worker(url);
        result.dedicated = await ask(() => w.postMessage(READER), (done) => { w.onmessage = (e) => done(e.data); });
        w.terminate();
    } catch (e) { result.dedicated = { error: String(e && e.message || e) }; }

    try {
        const sw = new SharedWorker(url);
        sw.port.start();
        result.shared = await ask(() => sw.port.postMessage(READER), (done) => { sw.port.onmessage = (e) => done(e.data); });
    } catch (e) { result.shared = { error: String(e && e.message || e) }; }

    // Flatten to one key per realm+member so expr-diff.mjs reports the member
    // that differs rather than "the whole object differs".
    const flat = {};
    for (const [realm, rec] of Object.entries(result)) {
        if (!rec || typeof rec !== 'object') { flat[realm] = String(rec); continue; }
        for (const [k, v] of Object.entries(rec)) flat[`${realm}.${k}`] = v === undefined ? 'undefined' : v;
    }
    return JSON.stringify(flat);
})()
