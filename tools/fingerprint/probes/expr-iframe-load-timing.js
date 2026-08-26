// When does a freshly appended about:blank iframe become ready, relative to the
// other async primitives around it?
//
// With the realm defect out of the way, the two arms make the same eight
// `getContext` calls on the same receivers through the Akamai sensor -- in a
// different order. The collector the sensor runs on a hidden iframe (`SNK`,
// called from `TEY`, the one that compares the child frame's GPU strings against
// the top frame's) lands 36th out of 99 here and 87th in Chrome, and the two
// offscreen-canvas groups are swapped with it. The sensor drives its collectors
// through a generator, so what the sequence records is completion order, and the
// iframe collector's completion is gated on the frame being ready.
//
// So: how many turns does that take. Everything below is stamped against a
// counter that ticks once per microtask drain and once per macrotask, which is
// the only clock that matters for an ordering question -- wall clock would just
// measure that this engine is slower.
(() => {
    const marks = [];
    let ticks = 0;
    const mark = (what) => marks.push(what + '@' + ticks);

    const f = document.createElement('iframe');
    f.style.display = 'none';
    f.addEventListener('load', () => mark('iframe-load'));

    mark('before-append');
    document.body.appendChild(f);
    mark('after-append');

    // Readable straight away, or only once the frame has run?
    let ready = null;
    try {
        ready = String(f.contentDocument && f.contentDocument.readyState);
    } catch (e) {
        ready = 'threw';
    }

    return new Promise((resolve) => {
        // A microtask chain and a macrotask chain, both ticking the same counter,
        // so `iframe-load@N` says which turn the load event landed on.
        const microChain = (n) => {
            if (n === 0) return;
            Promise.resolve().then(() => {
                ticks++;
                mark('micro');
                microChain(n - 1);
            });
        };
        const macroChain = (n) => {
            if (n === 0) {
                resolve({
                    readyStateRightAfterAppend: ready,
                    marks,
                    loadIndex: marks.findIndex((m) => m.startsWith('iframe-load')),
                    loadMark: marks.find((m) => m.startsWith('iframe-load')) || 'never fired',
                    contentDocumentReadyStateAtEnd: (() => {
                        try {
                            return String(f.contentDocument.readyState);
                        } catch (e) {
                            return 'threw';
                        }
                    })(),
                });
                return;
            }
            setTimeout(() => {
                ticks++;
                mark('macro');
                macroChain(n - 1);
            }, 0);
        };
        microChain(4);
        macroChain(4);
    });
})()
