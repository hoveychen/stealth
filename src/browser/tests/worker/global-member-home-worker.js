// Reports which object owns each member of a worker global, so the [Global]
// flattening can be checked one level at a time.
self.onmessage = () => {
  const holderOf = (name) => {
    if (Object.prototype.hasOwnProperty.call(self, name)) return 'self';
    for (let o = Object.getPrototypeOf(self); o; o = Object.getPrototypeOf(o)) {
      if (Object.prototype.hasOwnProperty.call(o, name)) {
        const d = Object.getOwnPropertyDescriptor(o, 'constructor');
        return (d && typeof d.value === 'function' ? d.value.name : '<anonymous>') + '.prototype';
      }
    }
    return null;
  };

  const chain = [];
  for (let o = Object.getPrototypeOf(self); o; o = Object.getPrototypeOf(o)) {
    const d = Object.getOwnPropertyDescriptor(o, 'constructor');
    chain.push(d && typeof d.value === 'function' ? d.value.name : '<anonymous>');
  }

  postMessage({
    proto_is_own_interface_prototype: Object.getPrototypeOf(self) === DedicatedWorkerGlobalScope.prototype,
    chain,
    dwgs_prototype_own: Object.getOwnPropertyNames(DedicatedWorkerGlobalScope.prototype).sort(),
    // One member per level of the chain.
    holder_onmessage: holderOf('onmessage'),
    holder_postMessage: holderOf('postMessage'),
    holder_fetch: holderOf('fetch'),
    holder_isSecureContext: holderOf('isSecureContext'),
    holder_addEventListener: holderOf('addEventListener'),
    holder_console: holderOf('console'),
  });
};
