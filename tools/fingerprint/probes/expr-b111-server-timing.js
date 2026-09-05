// What `Server-Timing` becomes, and when it survives a cross-origin load.
//
// Needs scratch/b111/st-server.mjs running: :9591 is the page's own origin,
// :9592 is a second one that opts into being timed only for `/tao`.
(async () => {
    const urls = [
        'http://127.0.0.1:9591/same',
        'http://127.0.0.1:9592/tao',
        'http://127.0.0.1:9592/plain',
    ];
    await Promise.all(urls.map((u) => fetch(u).then((r) => r.text()).catch((e) => String(e))));
    await new Promise((r) => setTimeout(r, 150));
    const out = {};
    for (const u of urls) {
        const e = performance.getEntriesByType('resource').filter((x) => x.name === u)[0];
        out[u] = e
            ? {
                n: e.serverTiming.length,
                items: e.serverTiming.map((s) => ({
                    name: s.name, duration: s.duration, description: s.description,
                    ctor: s.constructor && s.constructor.name,
                    json: s.toJSON ? s.toJSON() : null,
                })),
                frozen: Object.isFrozen(e.serverTiming),
                same: e.serverTiming === e.serverTiming,
            }
            : '(no entry)';
    }
    out.nav = {
        n: performance.getEntriesByType('navigation')[0].serverTiming.length,
        items: performance.getEntriesByType('navigation')[0].serverTiming.map((s) => s.name),
    };
    return out;
})()
