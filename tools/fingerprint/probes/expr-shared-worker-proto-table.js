// expr-worker-proto-table.js taken inside a *shared* worker rather than a
// dedicated one. The two realms are not the same: the global's own interface
// differs (SharedWorkerGlobalScope vs DedicatedWorkerGlobalScope), and the
// Akamai interstitial on macys runs its sensor from a SharedWorker -- it reads
// `SharedWorker.port` 266 times and `SharedWorkerGlobalScope.close` once per
// round (results/b50-prop-reads-replay.json).
//
// A shared worker cannot postMessage to its creator directly; the reading
// comes back over the port handed to `onconnect`.
(async () => {
    const src = `
      const collect = () => {
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
        return JSON.stringify(out);
      };
      onconnect = (e) => { e.ports[0].postMessage(collect()); };
    `;
    const url = URL.createObjectURL(new Blob([src], { type: 'text/javascript' }));
    const w = new SharedWorker(url);
    const data = await new Promise((resolve, reject) => {
        w.port.onmessage = (e) => resolve(e.data);
        w.onerror = (e) => reject(new Error('shared worker error: ' + (e.message || e.type)));
        w.port.start();
        setTimeout(() => reject(new Error('shared worker timeout')), 8000);
    });
    return data;
})()
