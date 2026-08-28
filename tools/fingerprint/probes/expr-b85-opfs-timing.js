// The OPFS timing probe Kasada runs in a worker, reassembled from its heap.
//
// Fragments recovered by kasada-decode-pool.mjs, in heap order:
//   (async()=>{try{
//   const d=await navigator.storage.getDirectory(),
//   b=new Uint8Array(1);let m=1/0,s,i=0;
//   f.close();postMessage(m<.1)
//   }catch{postMessage(false)}})()
// So: open the origin-private file system, take a sync access handle, time the
// tightest write it can, and report whether the floor is under 0.1ms. An engine
// without OPFS never reaches the timer -- it takes the catch and answers false,
// which is a different answer from Chrome's rather than a missing one.
//
// This runs the same shape on the page thread, which is enough to say whether
// the surface exists and what the floor is; the worker is where the guard runs
// it, and worker-arm-probe.mjs is the tool for that half.
(async () => {
    const out = {};
    out.hasStorage = typeof navigator.storage;
    out.hasGetDirectory = navigator.storage && typeof navigator.storage.getDirectory;
    try {
        const d = await navigator.storage.getDirectory();
        out.gotDirectory = String(d && d.constructor && d.constructor.name);
        out.hasGetFileHandle = typeof d.getFileHandle;
        const fh = await d.getFileHandle('b85probe', { create: true });
        out.gotFileHandle = String(fh && fh.constructor && fh.constructor.name);
        out.hasCreateSyncAccessHandle = typeof fh.createSyncAccessHandle;
        const f = await fh.createSyncAccessHandle();
        out.gotSyncHandle = String(f && f.constructor && f.constructor.name);
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
    return JSON.stringify(out, null, 1);
})()
