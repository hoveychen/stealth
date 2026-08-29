// The whole set of resource entries one page produces, by initiatorType and in
// buffer order.
//
// B64's live-station census says the gap is one entry: Chrome's pre-ticket top
// document on cf-scrapingcourse is `script:2 img:1 xhr:1 other:1 iframe:1`,
// 6 entries and 708 bytes of names, and this engine's is the same minus the
// `iframe` — 5 entries, 562 bytes. This asks the same question on a fixture, so
// the answer is reproducible and does not cost a station visit.
//
// Order is reported as well as membership, because `resource-entry-buffer-order`
// is a separate open plan about exactly that and a fix here must not be read as
// having settled it.
//
//   node tools/fingerprint/probes/b86-initiator-fixture.mjs 8720 &
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-b86-initiator-set.js \
//        --url http://127.0.0.1:8720/page.html
(() => {
    const ready = window.__done || Promise.resolve();
    return Promise.resolve(ready).then(() => {
        const entries = performance.getEntriesByType('resource');
        const counts = {};
        for (const e of entries) counts[e.initiatorType] = (counts[e.initiatorType] || 0) + 1;

        const out = {
            count: String(entries.length),
            // Sorted, so membership is comparable independently of order.
            byInitiator: Object.keys(counts).sort().map((k) => k + ':' + counts[k]).join(' '),
            // Unsorted, so the arrival order is visible beside it.
            order: entries.map((e) => e.initiatorType).join(','),
            names: entries.map((e) => e.name.split('/').pop()).join(','),
            // The scalar B64's dose sweep is keyed on, so the two arms can be
            // compared on it directly rather than by counting entries.
            nameBytes: String(entries.reduce((n, e) => n + e.name.length, 0)),
        };
        // Whether the <iframe> element left a trace at all, under any spelling:
        // "iframe" is Chrome's answer, but an engine could plausibly file it as
        // "other" or "navigation", and "no entry at all" is a third answer.
        const framed = entries.filter((e) => e.name.indexOf('frame.html') !== -1);
        out.iframeEntries = String(framed.length);
        out.iframeInitiator = framed.map((e) => e.initiatorType).join(',') || '(none)';
        return out;
    });
})()
