(() => {
  const out = {};
  for (const n of ['XMLHttpRequest','XMLHttpRequestEventTarget','Navigator','Element','Performance','Screen','MessagePort','Storage']) {
    try { out[n] = Object.getOwnPropertyNames(self[n].prototype).sort().join(','); }
    catch (e) { out[n] = 'absent'; }
  }
  return JSON.stringify(out);
})()
