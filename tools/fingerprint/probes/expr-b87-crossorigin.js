// The four fields Resource Timing makes opaque for a cross-origin entry that
// did not opt in, read per entry so the rule can be seen rather than inferred.
//
// Opaque means: encoded/decoded body size and transferSize read 0,
// nextHopProtocol is the empty string, and the connection walk between
// fetchStart and responseStart collapses onto fetchStart. `Timing-Allow-Origin`
// on the response turns all of it back on.
//
//   node tools/fingerprint/probes/b87-crossorigin-fixture.mjs 8730 8731 &
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-b87-crossorigin.js \
//        --url http://127.0.0.1:8730/page.html
(() => {
    const ready = window.__done || Promise.resolve();
    return Promise.resolve(ready).then(() => {
        const rows = performance.getEntriesByType('resource').map((e) => {
            const tag = e.name.split('/').pop().split('?')[0];
            // "collapsed" is the whole connection walk sitting exactly on
            // fetchStart, which is what an opaque entry reports. Zero is a
            // third answer and is reported as its own word so it cannot be
            // confused with the collapse.
            const walk = [e.domainLookupStart, e.domainLookupEnd, e.connectStart, e.connectEnd, e.requestStart];
            const collapsed = walk.every((v) => v === e.fetchStart) ? 'collapsed'
                : walk.every((v) => v === 0) ? 'zero' : 'real';
            return [
                tag,
                'proto=' + (e.nextHopProtocol === '' ? '(empty)' : e.nextHopProtocol),
                'enc=' + e.encodedBodySize,
                'dec=' + e.decodedBodySize,
                'xfer=' + e.transferSize,
                'walk=' + collapsed,
                // The rest of the fields an opaque entry could plausibly also
                // blank, read rather than assumed -- writing the fix off a
                // remembered spec instead of a reading is how the wrong subset
                // gets zeroed.
                'status=' + e.responseStatus,
                'ctype=' + (e.contentType === '' ? '(empty)' : e.contentType),
                'cenc=' + (e.contentEncoding === '' ? '(empty)' : e.contentEncoding),
                'delivery=' + (e.deliveryType === '' ? '(empty)' : e.deliveryType),
                'blocking=' + e.renderBlockingStatus,
                'rstart=' + (e.responseStart === 0 ? '0' : e.responseStart === e.fetchStart ? '=fetchStart' : 'real'),
                'hstart=' + (e.finalResponseHeadersStart === 0 ? '0' : 'nonzero'),
                'wstart=' + e.workerStart,
                'rdir=' + e.redirectStart + '/' + e.redirectEnd,
                'sconn=' + e.secureConnectionStart,
            ].join(' ');
        });
        return { count: String(rows.length), rows: rows.join(' | ') };
    });
})()
