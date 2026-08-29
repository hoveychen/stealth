// Holds b87-wire-order-fixture.mjs open long enough for its late loads, and
// reports the buffer's own view beside it. The reading that matters is the
// server's arrival log, which the fixture prints; this is the corroborating
// in-page half, so a difference between "what we asked for" and "what we say we
// asked for" cannot hide.
//
//   node tools/fingerprint/probes/b87-wire-order-fixture.mjs 8722 &
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-b87-wire-order.js \
//        --url http://127.0.0.1:8722/page.html
(() => {
    const ready = window.__done || Promise.resolve();
    return Promise.resolve(ready).then(() => {
        const entries = performance.getEntriesByType('resource');
        const tag = (e) => e.name.split('/').pop().split('?')[0];
        return {
            count: String(entries.length),
            order: entries.map(tag).join(','),
            initiators: entries.map((e) => tag(e) + ':' + e.initiatorType).join(' '),
            startTimes: entries.map((e) => tag(e) + '=' + e.startTime.toFixed(1)).join(' '),
        };
    });
})()
