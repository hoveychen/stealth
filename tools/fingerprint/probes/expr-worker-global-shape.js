// Where a worker global's members live. Web IDL [Global] says the same thing
// for DedicatedWorkerGlobalScope as it says for Window -- members become own
// properties of the global -- but that is a claim to measure, not to assume,
// because this engine's window and worker realms are built by the same code and
// a fix aimed at one lands on both.
(async () => {
    const src = `
      const shape = (d) => d === undefined ? null : {
        is_getter: typeof d.get === 'function',
        enumerable: d.enumerable,
        configurable: d.configurable,
      };
      const holderOf = (name) => {
        if (Object.prototype.hasOwnProperty.call(self, name)) return 'self';
        for (let o = Object.getPrototypeOf(self); o; o = Object.getPrototypeOf(o)) {
          if (Object.prototype.hasOwnProperty.call(o, name)) {
            const c = Object.getOwnPropertyDescriptor(o, 'constructor');
            return (c && typeof c.value === 'function' ? c.value.name : '<anonymous>') + '.prototype';
          }
        }
        return null;
      };
      const chain = [];
      for (let o = Object.getPrototypeOf(self); o; o = Object.getPrototypeOf(o)) {
        const c = Object.getOwnPropertyDescriptor(o, 'constructor');
        chain.push({
          name: c && typeof c.value === 'function' ? c.value.name : '<anonymous>',
          own_count: Object.getOwnPropertyNames(o).length,
        });
      }
      postMessage({
        proto_is_DWGS_prototype: Object.getPrototypeOf(self) === DedicatedWorkerGlobalScope.prototype,
        chain,
        self_own_count: Object.getOwnPropertyNames(self).length,
        DWGS_prototype_own: Object.getOwnPropertyNames(DedicatedWorkerGlobalScope.prototype).sort(),
        WGS_prototype_own: Object.getOwnPropertyNames(WorkerGlobalScope.prototype).sort(),
        // One member from each level.
        holder_onmessage: holderOf('onmessage'),
        holder_isSecureContext: holderOf('isSecureContext'),
        holder_fetch: holderOf('fetch'),
        holder_addEventListener: holderOf('addEventListener'),
        isSecureContext_on_self: shape(Object.getOwnPropertyDescriptor(self, 'isSecureContext')),
        isSecureContext_on_WGS_prototype: shape(Object.getOwnPropertyDescriptor(WorkerGlobalScope.prototype, 'isSecureContext')),
      });
    `;
    const url = URL.createObjectURL(new Blob([src], { type: 'text/javascript' }));
    const w = new Worker(url);
    const data = await new Promise((resolve, reject) => {
        w.onmessage = (e) => resolve(e.data);
        w.onerror = (e) => reject(new Error('worker error: ' + (e.message || e.type)));
        setTimeout(() => reject(new Error('worker timeout')), 5000);
    });
    return JSON.stringify(data);
})()
