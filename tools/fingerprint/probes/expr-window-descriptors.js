// configurable/enumerable/writable for every own property of `window`, so a
// descriptor mismatch can be read as a list rather than found one name at a time.
(() => {
  const out = {};
  for (const k of Object.getOwnPropertyNames(window)) {
    let d;
    try { d = Object.getOwnPropertyDescriptor(window, k); } catch (e) { out[k] = 'THREW'; continue; }
    if (!d) { out[k] = 'absent'; continue; }
    out[k] = (d.get || d.set ? 'a' : 'v')
      + (d.get ? 'g' : '') + (d.set ? 's' : '')
      + (d.enumerable ? 'E' : 'e') + (d.configurable ? 'C' : 'c')
      + ('writable' in d ? (d.writable ? 'W' : 'w') : '');
  }
  return JSON.stringify(out);
})()
