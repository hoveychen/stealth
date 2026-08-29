// Every resource entry on the mixed-initiator fixture, with the timestamps the
// buffer is ordered by, so a wrong ORDER can be told apart from a wrong VALUE.
//
// `resource-entry-buffer-order` was opened on the reading that our buffer comes
// back `iframe,script,link,img,…` where Chrome's is `link,script,img,iframe,…`.
// That is a symptom shared by two very different causes: a buffer that sorts on
// the wrong key, and a buffer that sorts on the right key over wrong numbers.
// b87-order-fixture.mjs settled the key (both arms: queued at completion, read
// back by startTime). This asks what the numbers are.
//
//   node tools/fingerprint/probes/b86-initiator-fixture.mjs 8720 &
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-b87-initiator-times.js \
//        --url http://127.0.0.1:8720/page.html
(() => {
    const ready = window.__done || Promise.resolve();
    return Promise.resolve(ready).then(() => {
        const entries = performance.getEntriesByType('resource');
        const tag = (e) => e.name.split('/').pop().split('?')[0];
        const nav = performance.getEntriesByType('navigation')[0];
        const out = {
            order: entries.map((e) => e.initiatorType).join(','),
            names: entries.map(tag).join(','),
            // Ordered as the buffer holds them, so a non-monotonic startTime
            // column is itself the finding.
            startTimes: entries.map((e) => tag(e) + '=' + e.startTime.toFixed(1)).join(' '),
            fetchStarts: entries.map((e) => tag(e) + '=' + e.fetchStart.toFixed(1)).join(' '),
            responseEnds: entries.map((e) => tag(e) + '=' + e.responseEnd.toFixed(1)).join(' '),
            // startTime is defined as equal to fetchStart for a resource entry
            // with no redirect. Anywhere they disagree is a second bug.
            startEqualsFetch: String(entries.every((e) => e.startTime === e.fetchStart)),
            sortedByStart: String(entries.every((e, i) => i === 0 || entries[i - 1].startTime <= e.startTime)),
            // The document's own timeline, for scale: an entry whose startTime
            // sits before responseEnd of the HTML was issued by the parser.
            navResponseEnd: nav ? nav.responseEnd.toFixed(1) : '(none)',
            navDomContentLoaded: nav ? nav.domContentLoadedEventStart.toFixed(1) : '(none)',
        };
        return out;
    });
})()
