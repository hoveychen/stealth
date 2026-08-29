// Whether the parent's `iframe` resource entry is stated in the PARENT's time
// origin or in the CHILD's.
//
// B86 taught the parent to record an entry for the <iframe> element by copying
// the child frame's own navigation record. A copied record carries the child's
// numbers, and the child's timeline starts at its own navigationStart -- so
// unless the copy is rebased, the parent reports a subresource that began
// before the elements above it in its own document were even parsed.
//
// The test is arithmetic, not eyeballing: if parent.iframeEntry.startTime is
// (near) equal to the CHILD's own navigation startTime, the numbers were never
// translated. If it is equal to the child's start measured on the parent's
// clock, they were.
//
//   node tools/fingerprint/probes/b86-initiator-fixture.mjs 8720 &
//   node tools/fingerprint/run-expr.mjs chrome tools/fingerprint/probes/expr-b87-iframe-timebase.js \
//        --url http://127.0.0.1:8720/page.html
(() => {
    const ready = window.__done || Promise.resolve();
    return Promise.resolve(ready).then(() => {
        const framed = performance.getEntriesByType('resource')
            .filter((e) => e.name.indexOf('frame.html') !== -1)[0];
        const out = {
            parentEntry: framed
                ? 'start=' + framed.startTime.toFixed(1) + ' end=' + framed.responseEnd.toFixed(1)
                : '(no iframe entry)',
            // The earliest subresource the parent's own parser started. The
            // <iframe> is BELOW the link/script/img in the document, so its
            // fetch cannot precede theirs.
            earliestOtherStart: (() => {
                const rest = performance.getEntriesByType('resource')
                    .filter((e) => e.name.indexOf('frame.html') === -1);
                return rest.length ? Math.min.apply(null, rest.map((e) => e.startTime)).toFixed(1) : '(none)';
            })(),
            iframeStartsBeforeSiblings: '(unset)',
        };
        out.iframeStartsBeforeSiblings = String(
            framed != null && framed.startTime < Number(out.earliestOtherStart),
        );

        // Same-origin, so the child's own timeline is readable directly.
        try {
            const child = window.frames[0];
            const cnav = child.performance.getEntriesByType('navigation')[0];
            out.childNavOwnClock = cnav
                ? 'start=' + cnav.startTime.toFixed(1) + ' end=' + cnav.responseEnd.toFixed(1)
                : '(none)';
            // The offset between the two documents' time origins. A same-origin
            // child navigated after its parent has a POSITIVE origin offset.
            out.originOffset = (child.performance.timeOrigin - performance.timeOrigin).toFixed(1);
        } catch (e) {
            out.childNavOwnClock = '(threw: ' + e.name + ')';
            out.originOffset = '(threw)';
        }
        return out;
    });
})()
