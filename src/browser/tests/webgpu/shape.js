// The descriptor rendering probe-win37.js used against Chrome 150, so the
// expected strings in the webgpu tests can be pasted straight from its output.
// Symbols render by function name rather than source text: the `[native code]`
// wording is V8's and not worth pinning.
(() => {
  const flags = (d) => `${d.enumerable ? 'e' : '-'}${d.configurable ? 'c' : '-'}${'writable' in d ? (d.writable ? 'w' : '-') : '-'}`;

  window.gpuShape = function (o) {
    const out = [];
    for (const k of Object.getOwnPropertyNames(o)) {
      if (k === 'constructor') continue;
      const d = Object.getOwnPropertyDescriptor(o, k);
      if (d.get || d.set) out.push(`${d.get ? (d.set ? 'accessor' : 'get') : 'set'} ${k}[${flags(d)}]`);
      else if (typeof d.value === 'function') out.push(`${k}/${d.value.length}[${flags(d)}]`);
      else out.push(`${k}=${String(d.value)}[${flags(d)}]`);
    }
    for (const s of Object.getOwnPropertySymbols(o)) {
      const v = o[s];
      out.push(`@@${String(s).replace(/^Symbol\(Symbol\.(.*)\)$/, '$1')}=${typeof v === 'function' ? `fn:${v.name}` : String(v)}`);
    }
    return out.join(',');
  };

  window.gpuWindowFlags = (name) => flags(Object.getOwnPropertyDescriptor(window, name));

  // Asserts the parts every GPU* interface object shares: arity 0, a plain
  // function on Function.prototype, unconstructable, and a non-enumerable,
  // configurable, writable data property of the global.
  window.gpuExpectInterfaceObject = function (name, opts) {
    const ctor = window[name];
    testing.expectEqual('function', typeof ctor);
    testing.expectEqual(name, ctor.name);
    testing.expectEqual(0, ctor.length);
    testing.expectEqual('-cw', gpuWindowFlags(name));
    testing.expectTrue(Object.getPrototypeOf(ctor) === ((opts && opts.inherits) || Function.prototype));
    testing.expectTrue(Object.getPrototypeOf(ctor.prototype) === ((opts && opts.protoOf) || Object.prototype));

    // `prototype` itself is non-enumerable, non-configurable, non-writable.
    const pd = Object.getOwnPropertyDescriptor(ctor, 'prototype');
    testing.expectFalse(pd.enumerable);
    testing.expectFalse(pd.configurable);
    testing.expectFalse(pd.writable);

    // No statics beyond length/name/prototype.
    testing.expectEqual(
      [],
      Object.getOwnPropertyNames(ctor).filter((k) => !['length', 'name', 'prototype'].includes(k)),
    );

    testing.expectError(`Failed to construct '${name}': Illegal constructor`, () => new ctor());
    testing.expectError('Illegal constructor', () => ctor());
  };
})();
