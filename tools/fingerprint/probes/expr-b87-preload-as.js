// Which preloads left a resource entry, and under what initiatorType. Chrome
// files a `<link rel=preload>` under "link" whatever the `as` says; an engine
// that never made the request files nothing at all, and the two are only
// distinguishable by asking.
//
//   node tools/fingerprint/probes/b87-preload-as-fixture.mjs 8760 &
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-b87-preload-as.js \
//        --url http://127.0.0.1:8760/page.html
(() => {
    const ready = window.__done || Promise.resolve();
    return Promise.resolve(ready).then(() => {
        const entries = performance.getEntriesByType('resource')
            .filter((e) => e.name.indexOf('/p-') !== -1);
        return {
            count: String(entries.length),
            rows: entries
                .map((e) => e.name.split('/').pop() + ':' + e.initiatorType)
                .sort()
                .join(' '),
        };
    });
})()
