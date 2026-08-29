// Buffer order against the two candidate sort keys, on a page whose loads
// finish in the reverse of the order they start in (b87-order-fixture.mjs).
//
// `order` is what `getEntriesByType` says. `byResponseEnd` and `byStartTime`
// are the same entries sorted by each candidate key, so the answer is whichever
// pair match -- and if the two candidates agree, the fixture failed to separate
// them (the engine loaded serially) and the reading proves nothing.
//
// `observed` is the order a PerformanceObserver -- registered by the fixture
// page itself, before the images -- saw them arrive in, which is insertion
// order and nothing else. Reading both separates two questions that look like
// one: what order entries are *queued* in (completion), and what order a *read*
// hands them back in (Performance Timeline sorts by startTime). An engine can
// get the first right and the second wrong.
//
//   node tools/fingerprint/probes/b87-order-fixture.mjs 8721 &
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-b87-order.js \
//        --url http://127.0.0.1:8721/page.html
(() => {
    const ready = window.__done || Promise.resolve();
    // Registered as late as this expression can manage; the fixture holds the
    // page open for 1.6s, so nothing has finished loading yet.
    const seen = window.__arrivals || ['(fixture recorded none)'];
    return Promise.resolve(ready).then(() => {
        const gif = (n) => n.indexOf('.gif') !== -1;
        const entries = performance.getEntriesByType('resource').filter((e) => gif(e.name));
        const tag = (n) => n.split('/').pop().split('?')[0];
        const by = (key) => entries.slice().sort((x, y) => x[key] - y[key]).map((e) => tag(e.name)).join(',');
        return {
            count: String(entries.length),
            order: entries.map((e) => tag(e.name)).join(','),
            observed: seen.filter(gif).map(tag).join(','),
            byResponseEnd: by('responseEnd'),
            byStartTime: by('startTime'),
            // Three decimals: the three images are issued within a millisecond
            // of each other, and a rounded reading cannot show which came first.
            responseEnds: entries.map((e) => tag(e.name) + '=' + e.responseEnd.toFixed(3)).join(' '),
            startTimes: entries.map((e) => tag(e.name) + '=' + e.startTime.toFixed(3)).join(' '),
            // If these two are equal the fixture did not separate the keys.
            keysSeparated: String(by('responseEnd') !== by('startTime')),
        };
    });
})()
