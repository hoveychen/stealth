// The inheritance chain of every interface the realm carries, as
// `X -> Parent -> Parent`. This is the column `expr-constructor-slot.js`
// cannot see: it records each prototype's *own* names, so an interface that
// inherits from the wrong thing -- or from nothing -- reads as a two-name gap
// rather than a missing base class.
//
// That is not hypothetical. OffscreenCanvas was a prototype root in this
// engine and inherits EventTarget in Chrome, which the member table showed
// only as "missing oncontextlost, oncontextrestored" while
// `oc instanceof EventTarget` was false and `oc.addEventListener` undefined --
// two one-expression tells the member table never mentioned.
//
// Run it against both arms on the same https page and diff with proto-gap.mjs
// (each value is a comma-joined chain, so a differing chain shows as a row).
(() => {
  const out = {};
  const nameOf = (proto) => {
    const d = Object.getOwnPropertyDescriptor(proto, 'constructor');
    return d && typeof d.value === 'function' ? d.value.name : '<anonymous>';
  };
  for (const key of Object.getOwnPropertyNames(self)) {
    let ctor;
    try { ctor = self[key]; } catch (e) { continue; }
    if (typeof ctor !== 'function') continue;
    let proto;
    try { proto = ctor.prototype; } catch (e) { continue; }
    if (!proto || typeof proto !== 'object') continue;
    if (ctor.name !== key) continue;
    const chain = [key];
    for (let p = Object.getPrototypeOf(proto); p; p = Object.getPrototypeOf(p)) {
      chain.push(nameOf(p));
    }
    out[key] = chain.join(',');
  }
  return JSON.stringify(out);
})()
