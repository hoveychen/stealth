// Every resource entry this document filed for a load from ANOTHER origin, with
// the fields the cross-origin rule governs. For re-taking B66's live
// cf-scrapingcourse reading, where this engine handed the page the Turnstile
// widget document's exact byte count (101104) and Chrome handed over a zero.
//
// Same-origin entries are dropped rather than reported: on a real page there
// are dozens of them, they are all supposed to be fully populated, and they
// would bury the handful this is about.
//
//   node tools/fingerprint/run-expr.mjs lightpanda \
//     tools/fingerprint/probes/expr-b87-station-opacity.js \
//     --url https://www.scrapingcourse.com/cloudflare-challenge
(() => new Promise((done) => {
    // The widget's document is fetched well after load, so a read taken at load
    // sees nothing -- but a fixed long wait outlives the page: a solved
    // challenge navigates, and the evaluation dies with "Inspected target
    // navigated or closed". So poll, and answer the moment the cross-origin
    // entries are there.
    const deadline = Date.now() + 8000;
    const poll = () => {
        const here = location.origin;
        const seen = performance.getEntriesByType('resource')
            .filter((e) => { try { return new URL(e.name).origin !== here; } catch (_) { return false; } });
        if (seen.length < 2 && Date.now() < deadline) {
            return void setTimeout(poll, 250);
        }
        report();
    };
    const report = () => {
        const here = location.origin;
        const rows = performance.getEntriesByType('resource')
            .filter((e) => {
                try { return new URL(e.name).origin !== here; } catch (_) { return false; }
            })
            .map((e) => {
                const walk = [e.domainLookupStart, e.domainLookupEnd, e.connectStart, e.connectEnd, e.requestStart];
                return [
                    // Origin plus the last path segment: the full URLs carry
                    // per-challenge tokens hundreds of characters long.
                    new URL(e.name).origin + '/…/' + e.name.split('/').pop().split('?')[0],
                    e.initiatorType,
                    'enc=' + e.encodedBodySize,
                    'xfer=' + e.transferSize,
                    'proto=' + (e.nextHopProtocol === '' ? '(empty)' : e.nextHopProtocol),
                    'walk=' + (walk.every((v) => v === 0) ? 'zero' : 'nonzero'),
                    'status=' + e.responseStatus,
                ].join(' ');
            });
        done({
            total: String(performance.getEntriesByType('resource').length),
            crossOrigin: String(rows.length),
            // Any non-zero here on an entry Chrome zeroes is the leak.
            leakedBytes: String(rows.reduce((n, r) => n + Number(r.match(/enc=(\d+)/)[1]), 0)),
            rows: rows.join(' | ') || '(none)',
        });
    };
    poll();
}))()
