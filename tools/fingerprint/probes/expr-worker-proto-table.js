// expr-constructor-slot.js, but taken inside a dedicated worker: every
// interface object the *worker* realm carries and the whole own-property name
// list of its prototype, plus the global's own names and its prototype chain.
//
// Why this realm and not the window's: the Akamai interstitial on macys runs
// its sensor from a SharedWorker and reads nine `WorkerNavigator` members
// there (measured, results/b50-prop-reads-replay.json). Every prototype table
// this repo has recorded since B46 was the window realm only, so the worker
// realm is unmeasured surface that a live challenge demonstrably walks.
(async () => {
    const src = `
      const out = {};
      for (const key of Object.getOwnPropertyNames(self)) {
        let ctor;
        try { ctor = self[key]; } catch (e) { continue; }
        if (typeof ctor !== 'function') continue;
        let proto;
        try { proto = ctor.prototype; } catch (e) { continue; }
        if (!proto || typeof proto !== 'object') continue;
        if (ctor.name !== key) continue;
        let names;
        try { names = Object.getOwnPropertyNames(proto); } catch (e) { continue; }
        if (names.indexOf('constructor') < 0) continue;
        out[key] = names.join(',');
      }
      const chain = [];
      for (let o = Object.getPrototypeOf(self); o; o = Object.getPrototypeOf(o)) {
        const c = Object.getOwnPropertyDescriptor(o, 'constructor');
        chain.push((c && typeof c.value === 'function' ? c.value.name : '<anonymous>')
          + ':' + Object.getOwnPropertyNames(o).join(','));
      }
      out['@global_own'] = Object.getOwnPropertyNames(self).join(',');
      out['@global_chain'] = chain.join(' | ');
      postMessage(JSON.stringify(out));
    `;
    const url = URL.createObjectURL(new Blob([src], { type: 'text/javascript' }));
    const w = new Worker(url);
    const data = await new Promise((resolve, reject) => {
        w.onmessage = (e) => resolve(e.data);
        w.onerror = (e) => reject(new Error('worker error: ' + (e.message || e.type)));
        setTimeout(() => reject(new Error('worker timeout')), 8000);
    });
    return data;
})()
