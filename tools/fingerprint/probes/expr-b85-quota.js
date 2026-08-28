// The storage figure the challenge realm encodes: ours is 10737418240 -- exactly
// 10 GiB -- every run, where Chrome was seen to answer both 10737418240 and
// 10737418391 within one session. A quota that never moves is the shape of a
// constant standing in for a measurement.
(async () => {
    const out = { samples: [] };
    for (let i = 0; i < 3; i++) {
        const e = await navigator.storage.estimate();
        out.samples.push({ quota: e.quota, usage: e.usage });
    }
    out.distinct = new Set(out.samples.map((s) => s.quota)).size;
    out.isRound = out.samples.map((s) => s.quota % (1024 * 1024 * 1024) === 0);
    return JSON.stringify(out);
})()
