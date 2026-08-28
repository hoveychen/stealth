// Kasada's OPFS timing probe, run where Kasada runs it: inside a worker.
//
// `createSyncAccessHandle` is worker-only by spec, so the page-thread reading is
// "absent" on both arms and says nothing. The guard's fragments -- `(async()=>
// {try{`, `const d=await navigator.storage.getDirectory(),`, `b=new
// Uint8Array(1);let m=1/0,s,i=0;`, `f.close();postMessage(m<.1)`,
// `}catch{postMessage(false)}})()` -- are a worker body, and this is that body
// with the timer loop written out, plus enough reporting to tell "no OPFS" from
// "OPFS but a slow floor" from "OPFS and a fast floor".
(async () => {
    const body = `
      (async () => {
        const out = { where: 'worker' };
        try {
          out.hasStorage = typeof navigator.storage;
          const d = await navigator.storage.getDirectory();
          out.gotDirectory = String(d && d.constructor && d.constructor.name);
          const fh = await d.getFileHandle('b85probe', { create: true });
          out.hasCreateSyncAccessHandle = typeof fh.createSyncAccessHandle;
          const f = await fh.createSyncAccessHandle();
          const b = new Uint8Array(1);
          let m = Infinity, s, i = 0;
          for (; i < 2000; i++) {
            s = performance.now();
            f.write(b, { at: 0 });
            const dt = performance.now() - s;
            if (dt < m) m = dt;
          }
          f.close();
          out.minWriteMs = m;
          out.verdict = m < 0.1;
        } catch (e) {
          out.threw = String(e && (e.message || e));
          out.verdict = false;
        }
        postMessage(JSON.stringify(out));
      })();
    `;
    const result = await new Promise((resolve) => {
        let w;
        const done = (v) => { try { w && w.terminate(); } catch (e) {} resolve(v); };
        setTimeout(() => done('{"timeout":true}'), 20000);
        try {
            const url = URL.createObjectURL(new Blob([body], { type: 'text/javascript' }));
            w = new Worker(url);
            w.onmessage = (e) => done(e.data);
            w.onerror = (e) => done(JSON.stringify({ workerError: String(e && (e.message || e)) }));
        } catch (e) {
            done(JSON.stringify({ spawnError: String(e && (e.message || e)) }));
        }
    });
    return result;
})()
