// Holds b87-crossorigin-request-fixture.mjs open while its loads go out. The
// reading that matters is the far server's header log, which the fixture
// prints; this only reports which of the loads left an entry, so a row missing
// from the server log can be told apart from a row the engine never requested.
//
//   node tools/fingerprint/probes/b87-crossorigin-request-fixture.mjs 8740 8741 &
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-b87-request-headers.js \
//        --url http://127.0.0.1:8740/page.html
(() => {
    const ready = window.__done || Promise.resolve();
    return Promise.resolve(ready).then(() => {
        const entries = performance.getEntriesByType('resource');
        return {
            count: String(entries.length),
            names: entries.map((e) => e.name.split('/').pop()).sort().join(','),
        };
    });
})()
