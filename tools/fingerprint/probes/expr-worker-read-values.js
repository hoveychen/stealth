// The values the challenge's sensor reads from inside a worker, read from
// inside one. Every member here is on the measured read path
// (results/b50-prop-reads-replay.json): nine on `WorkerNavigator`, seven on
// `WorkerGlobalScope`.
//
// The shapes of these two prototypes have been compared; their *answers* have
// not, in this realm. A worker builds its navigator from a different object
// than the window does, so "the window realm agrees" is not evidence about it
// -- and a sensor that runs in a worker and compares what it finds there
// against what the page told it is reading exactly this.
(async () => {
  const src = `
    const show = (v) => {
      if (v === null) return 'null';
      if (Array.isArray(v)) return 'array[' + v.join('|') + ']';
      const t = typeof v;
      if (t === 'object') return 'object:' + (v.constructor ? v.constructor.name : '?');
      if (t === 'function') return 'function:' + v.length + ':' + (/native code/.test(v.toString()) ? 'native' : 'js');
      return t + ':' + String(v);
    };
    const out = {};
    for (const k of ['appVersion', 'connection', 'deviceMemory', 'hardwareConcurrency',
      'language', 'languages', 'platform', 'userAgent', 'userAgentData']) {
      try { out['navigator.' + k] = show(navigator[k]); } catch (e) { out['navigator.' + k] = 'threw:' + e.name; }
    }
    for (const k of ['fetch', 'importScripts', 'queueMicrotask', 'setTimeout']) {
      try { out['self.' + k] = show(self[k]); } catch (e) { out['self.' + k] = 'threw:' + e.name; }
    }
    out['self.self'] = show(self.self) + '|is_self=' + (self.self === self);
    out['self.performance'] = show(self.performance) + '|stable=' + (self.performance === self.performance);
    out['self.navigator'] = show(self.navigator) + '|stable=' + (self.navigator === self.navigator);

    // The two objects behind the members above.
    try {
      const c = navigator.connection;
      out['connection.fields'] = c ? ['effectiveType', 'rtt', 'downlink', 'saveData', 'type']
        .map((k) => k + '=' + show(c[k])).join(' ') : 'null';
    } catch (e) { out['connection.fields'] = 'threw:' + e.name; }
    try {
      const u = navigator.userAgentData;
      out['uaData.fields'] = u ? ['brands', 'mobile', 'platform']
        .map((k) => k + '=' + (k === 'brands' ? JSON.stringify(u[k]) : show(u[k]))).join(' ') : 'null';
      out['uaData.getHighEntropyValues'] = show(u && u.getHighEntropyValues);
    } catch (e) { out['uaData.fields'] = 'threw:' + e.name; }

    // performance.now()'s clamp is a fingerprint of its own; report the step
    // rather than the value.
    const steps = new Set();
    let last = performance.now();
    for (let i = 0; i < 40000; i++) {
      const t = performance.now();
      if (t !== last) { steps.add(Math.round((t - last) * 1e6) / 1e6); last = t; }
    }
    out['performance.now.min_step'] = String(Math.min(...steps));
    out['performance.memory'] = show(performance.memory);

    postMessage(JSON.stringify(out));
  `;
  const url = URL.createObjectURL(new Blob([src], { type: 'text/javascript' }));
  const w = new Worker(url);
  return await new Promise((resolve, reject) => {
    w.onmessage = (e) => resolve(e.data);
    w.onerror = () => reject(new Error('worker error'));
    setTimeout(() => reject(new Error('worker timeout')), 15000);
  });
})()
