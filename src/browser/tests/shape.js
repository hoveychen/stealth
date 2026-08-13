// The descriptor rendering probe-win37.js and probe-win43.js use against
// Chrome 150, so the expected strings in the tests that pin an interface's
// shape can be pasted straight from a probe's output. Symbols render by
// function name rather than source text: the `[native code]` wording is V8's
// and not worth pinning.
(() => {
  const flags = (d) => `${d.enumerable ? 'e' : '-'}${d.configurable ? 'c' : '-'}${'writable' in d ? (d.writable ? 'w' : '-') : '-'}`;

  window.shapeOf = function (o) {
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

  window.windowFlags = (name) => flags(Object.getOwnPropertyDescriptor(window, name));

  // Asserts the parts every interface object shares: the declared arity, a
  // plain function on Function.prototype, and a non-enumerable, configurable,
  // writable data property of the global.
  //
  // Options: `arity` (default 0), `statics` (the names beyond
  // length/name/prototype, default none), `inherits` and `protoOf` for a
  // subclass, and `illegal` -- true, the default, for the whole GPU* family,
  // which cannot be constructed at all; false for an interface a page really
  // can `new`, where the only refusal left is calling it without `new`.
  window.expectInterfaceObject = function (name, opts) {
    const o = opts || {};
    const ctor = window[name];
    testing.expectEqual('function', typeof ctor);
    testing.expectEqual(name, ctor.name);
    testing.expectEqual(o.arity || 0, ctor.length);
    testing.expectEqual('-cw', windowFlags(name));
    testing.expectTrue(Object.getPrototypeOf(ctor) === (o.inherits || Function.prototype));
    testing.expectTrue(Object.getPrototypeOf(ctor.prototype) === (o.protoOf || Object.prototype));

    // `prototype` itself is non-enumerable, non-configurable, non-writable.
    const pd = Object.getOwnPropertyDescriptor(ctor, 'prototype');
    testing.expectFalse(pd.enumerable);
    testing.expectFalse(pd.configurable);
    testing.expectFalse(pd.writable);

    testing.expectEqual(
      o.statics || [],
      Object.getOwnPropertyNames(ctor).filter((k) => !['length', 'name', 'prototype'].includes(k)),
    );

    if (o.illegal === false) {
      testing.expectError(
        `Failed to construct '${name}': Please use the 'new' operator, this DOM object constructor cannot be called as a function.`,
        () => ctor(),
      );
      return;
    }
    testing.expectError(`Failed to construct '${name}': Illegal constructor`, () => new ctor());
    testing.expectError('Illegal constructor', () => ctor());
  };
})();
