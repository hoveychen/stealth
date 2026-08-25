// The resource-timing list, as the collector reads it.
//
// `prop-reads.mjs` against the macys interstitial has the collector calling
// `performance.getEntriesByType` twice and then reading `PerformanceEntry.name`
// fourteen times and `PerformanceResourceTiming.initiatorType` nine times. That
// is a *list* -- and the one remaining measured fact about the payload is that
// it is 50-60 bytes shorter than Chrome's while every fixed-width value in it
// matches (see the plan's note ⑪: forcing our geometry readings to Chrome's did
// not move the length by a byte). A list with a different number of entries is
// the shape that can do that, and this is the list the collector reads.
//
// Run it on the replay, which serves the same script set to both arms:
//   node run-expr.mjs lightpanda probes/expr-resource-entries.js --url http://127.0.0.1:PORT/
//   node run-expr.mjs chrome     probes/expr-resource-entries.js --url http://127.0.0.1:PORT/
(() => {
    const rs = performance.getEntriesByType('resource');
    const strip = (n) => String(n).replace(/^https?:\/\/127\.0\.0\.1:\d+/, '');
    const byInitiator = {};
    for (const r of rs) byInitiator[r.initiatorType] = (byInitiator[r.initiatorType] || 0) + 1;
    const nav = performance.getEntriesByType('navigation')[0];
    const out = {
        'resource.count': rs.length,
        'resource.byInitiator': JSON.stringify(byInitiator),
        // Names in load order, which is what a collector walking the list sees.
        'resource.names': JSON.stringify(rs.map((r) => `${r.initiatorType}|${strip(r.name)}`)),
        // Which of the numeric fields are non-zero is itself a reading: a zero
        // where Chrome has a number is a shorter number in whatever the
        // collector encodes, and a field it cannot read at all is an entry
        // missing from the list.
        'resource.zeroFields': JSON.stringify((() => {
            const fields = ['startTime', 'duration', 'domainLookupStart', 'domainLookupEnd',
                'connectStart', 'connectEnd', 'secureConnectionStart', 'requestStart',
                'responseStart', 'responseEnd', 'transferSize', 'encodedBodySize',
                'decodedBodySize', 'nextHopProtocol', 'responseStatus'];
            const tally = {};
            for (const f of fields) {
                let zero = 0, missing = 0;
                for (const r of rs) {
                    const v = r[f];
                    if (v === undefined) missing++;
                    else if (v === 0 || v === '') zero++;
                }
                tally[f] = `${zero}z/${missing}m`;
            }
            return tally;
        })()),
        'entryTypes': JSON.stringify(PerformanceObserver.supportedEntryTypes || []),
        'nav.type': nav ? nav.type : 'no-navigation-entry',
        'nav.loadEventEndPositive': nav ? nav.loadEventEnd > 0 : 'n/a',
        'nav.transferSizePositive': nav ? nav.transferSize > 0 : 'n/a',
        'marks': performance.getEntriesByType('mark').length,
        'paints': JSON.stringify(performance.getEntriesByType('paint').map((p) => p.name)),
    };
    return JSON.stringify(out);
})()
