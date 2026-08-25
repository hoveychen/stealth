(() => {
  const out = {};
  const names = ['Navigator','Document','HTMLElement','XMLHttpRequest','Performance','Screen','Element','Node','CSSStyleDeclaration','Storage','NetworkInformation','FontFaceSet','MessagePort','WebGLRenderingContext'];
  for (const n of names) {
    try {
      const p = self[n] && self[n].prototype;
      if (!p) { out[n] = 'absent'; continue; }
      const list = Object.getOwnPropertyNames(p);
      out[n] = `${list.indexOf('constructor')}/${list.length}`;
    } catch (e) { out[n] = 'throw'; }
  }
  return JSON.stringify(out);
})()
