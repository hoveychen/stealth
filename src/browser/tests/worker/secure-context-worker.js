// Reports the worker realm's own secure-context state, plus where on the
// prototype chain the property lives and what shape it has. Measured on a
// headed Chrome 151 from http://localhost:8777: the value is the *owner's*
// answer (true there), and isSecureContext is an enumerable, configurable
// getter on WorkerGlobalScope.prototype.
self.onmessage = () => {
  const shape = (d) => d === undefined ? null : {
    is_getter: typeof d.get === 'function',
    has_setter: d.set !== undefined,
    enumerable: d.enumerable,
    configurable: d.configurable,
  };

  // Above `self`, so the answer is about the interface prototype object rather
  // than about the [Global] flattening that mirrors members onto the global.
  let holder = null, on_prototype = null;
  for (let o = Object.getPrototypeOf(self); o; o = Object.getPrototypeOf(o)) {
    const d = Object.getOwnPropertyDescriptor(o, 'isSecureContext');
    if (d) {
      holder = (o.constructor && o.constructor.name) || '?';
      on_prototype = shape(d);
      break;
    }
  }

  postMessage({
    secure: self.isSecureContext,
    holder,
    on_prototype,
    on_self: shape(Object.getOwnPropertyDescriptor(self, 'isSecureContext')),
  });
};
