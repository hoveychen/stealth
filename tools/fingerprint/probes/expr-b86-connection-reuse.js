// Does a same-origin XHR get its own connection, or ride the one the
// navigation opened?
//
// Noticed in passing while fixing the XHR/fetch milestones: on
// https://example.com/ Chrome's XHR entry reported domainLookupStart and
// connectEnd well after fetchStart -- a fresh connection -- while this engine
// reported both equal to fetchStart, which `http.ResponseTimes` documents as
// what a REUSED connection answers. One reading, taken by a probe built for a
// different question, so this one exists to say whether that is systematic
// before anything is built on it.
//
// The signal is read off the entry rather than off the socket, because that is
// the only place a page can see it and it is symmetric across the two arms:
//
//   reused  -> domainLookupStart == domainLookupEnd == connectStart
//              == connectEnd == fetchStart
//   fresh   -> at least one of those is later than fetchStart
//
// `secureConnectionStart` is deliberately NOT in that predicate, and the first
// run is why: Chrome answers `secureConnectionStart == fetchStart` on a REUSED
// https connection -- non-zero -- so folding it in reported 6 of 6 as fresh
// when only the first two had opened a socket. It is reported beside the
// verdict instead, because the two arms disagree about it on its own terms:
// this engine answers 0 there.
//
// Sequential rather than parallel: parallel requests force extra connections in
// any browser, so firing them at once would manufacture the difference being
// measured.
(() => {
    const N = 6;
    const fresh = (e) => (
        e.domainLookupStart > e.fetchStart ||
        e.domainLookupEnd > e.fetchStart ||
        e.connectStart > e.fetchStart ||
        e.connectEnd > e.fetchStart
    );

    const one = (i) => new Promise((resolve) => {
        const x = new XMLHttpRequest();
        // A distinct query per request so each gets its own entry, and
        // cache-busting so none of them is answered without a round trip.
        x.open('GET', location.origin + '/?b86conn=' + i + '.' + Date.now());
        x.onloadend = () => setTimeout(resolve, 50);
        x.send();
    });

    let chain = Promise.resolve();
    for (let i = 0; i < N; i++) chain = chain.then(() => one(i));

    return chain.then(() => {
        const entries = performance.getEntriesByType('resource')
            .filter((e) => e.name.indexOf('b86conn=') !== -1);
        const out = {
            origin: location.origin,
            requested: String(N),
            entries: String(entries.length),
        };
        entries.forEach((e, i) => {
            out['r' + i] = [
                fresh(e) ? 'FRESH' : 'reused',
                'fetchStart=' + Math.round(e.fetchStart * 10) / 10,
                'dnsEnd=+' + Math.round((e.domainLookupEnd - e.fetchStart) * 10) / 10,
                'connectEnd=+' + Math.round((e.connectEnd - e.fetchStart) * 10) / 10,
                'tlsAtFetchStart=' + (e.secureConnectionStart === e.fetchStart),
                'tlsZero=' + (e.secureConnectionStart === 0),
                'reqStart=+' + Math.round((e.requestStart - e.fetchStart) * 10) / 10,
            ].join(' ');
        });
        out.freshCount = String(entries.filter(fresh).length) + '/' + entries.length;
        return out;
    });
})()
