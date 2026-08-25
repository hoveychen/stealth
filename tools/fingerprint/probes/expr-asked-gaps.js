(async () => {
  const out = {};
  const put = (k, f) => { try { const v = f(); out[k] = v === undefined ? 'undefined' : (v === null ? 'null' : String(v)); } catch (e) { out[k] = 'throw: ' + (e && e.message); } };
  put('SharedArrayBuffer', () => typeof SharedArrayBuffer);
  put('SharedArrayBuffer.ctor', () => { new SharedArrayBuffer(8); return 'constructs'; });
  put('ContentIndex', () => typeof self.ContentIndex);
  put('RestrictionTarget', () => typeof self.RestrictionTarget);
  put('AICreateMonitor', () => typeof self.AICreateMonitor);
  put('input.capture', () => 'capture' in document.createElement('input') ? typeof document.createElement('input').capture : 'absent');
  put('input.capture.value', () => { const i = document.createElement('input'); i.setAttribute('capture', 'user'); return i.capture; });
  put('fonts.iterator', () => typeof document.fonts[Symbol.iterator]);
  put('fonts.spread', () => Array.from(document.fonts).length);
  put('fonts.entries', () => typeof document.fonts.entries);
  put('fonts.forEach', () => typeof document.fonts.forEach);
  put('connection.type', () => navigator.connection ? navigator.connection.type : 'no-connection');
  put('connection.downlinkMax', () => navigator.connection ? navigator.connection.downlinkMax : 'n/a');
  put('connection.proto', () => navigator.connection ? Object.getOwnPropertyNames(Object.getPrototypeOf(navigator.connection)).sort().join(',') : 'n/a');
  const w = new Worker(URL.createObjectURL(new Blob([`self.onmessage = () => {
     const n = self.navigator;
     postMessage(JSON.stringify({
       connection: n.connection ? (n.connection.effectiveType + '/' + n.connection.rtt + '/' + n.connection.downlink + '/' + typeof n.connection.type) : 'absent',
       connProto: n.connection ? Object.getOwnPropertyNames(Object.getPrototypeOf(n.connection)).sort().join(',') : 'n/a',
       sab: typeof SharedArrayBuffer,
       keys: Object.getOwnPropertyNames(Object.getPrototypeOf(n)).sort().join(','),
     }));
   };`], { type: 'text/javascript' })));
  out.worker = await new Promise((res) => {
    const t = setTimeout(() => res('timeout'), 6000);
    w.onmessage = (e) => { clearTimeout(t); res(e.data); };
    w.postMessage(1);
  });
  return JSON.stringify(out);
})()
