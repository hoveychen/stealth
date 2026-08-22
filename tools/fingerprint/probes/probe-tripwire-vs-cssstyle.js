// Does replacing the prototype above CSSStyleDeclaration.prototype change what
// a CSS property read answers? Reads the same name before and after, on one
// object, so the only difference is the tripwire.
(async () => {
  const d = document.createElement('div');
  d.style.position = 'absolute';
  document.body.appendChild(d);
  const cs = window.getComputedStyle(d);
  const keys = ['contentVisibility', 'display', 'opacity', 'position', 'transform', 'visibility'];
  const read = () => Object.fromEntries(keys.map((k) => [k, typeof cs[k] === 'undefined' ? 'UNDEFINED' : JSON.stringify(String(cs[k]))]));
  const out = { before: read() };

  const OP = Object.prototype;
  const hits = [];
  const trap = new Proxy(OP, {
    get(t, k, r) {
      if (typeof k === 'string' && !(k in t)) hits.push(k + ' on ' + OP.toString.call(r));
      return Reflect.get(t, k, r);
    },
  });
  const targets = [];
  for (const n of Object.getOwnPropertyNames(globalThis)) {
    let C;
    try { C = globalThis[n]; } catch { continue; }
    if (typeof C !== 'function') continue;
    let P;
    try { P = C.prototype; } catch { continue; }
    if (!P || typeof P !== 'object') continue;
    try { if (Object.getPrototypeOf(P) !== OP) continue; } catch { continue; }
    targets.push([n, P]);
  }
  out.wrappedCount = targets.length;
  out.wrappedIncludesCSS = targets.some(([n]) => n === 'CSSStyleDeclaration');
  for (const [, P] of targets) { try { Object.setPrototypeOf(P, trap); } catch { } }

  out.afterSameObject = read();
  out.afterFreshObject = (() => {
    const cs2 = window.getComputedStyle(d);
    return Object.fromEntries(keys.map((k) => [k, typeof cs2[k] === 'undefined' ? 'UNDEFINED' : JSON.stringify(String(cs2[k]))]));
  })();
  out.trapHits = hits.filter((h) => /CSSStyleDeclaration/.test(h));
  return out;
})()
