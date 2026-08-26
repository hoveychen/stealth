// Does Kasada's /tl payload carry an enumeration of `window`?
//
// The payload this engine posts to x-hyatt is a stable ~600 bytes shorter than
// Chrome's (19042/19002 here against 19602/19602/19594, three sittings), and
// with the protocol layer ruled out that shortfall is the only place left for
// the refusal to live. Before spending a plan on *which* answers are short, one
// question decides the shape of the search: is the payload's length a function
// of how many properties `window` has?
//
// So: plant a known number of own properties with names of a known length, and
// read `postLen` off the trace. If the body grows by roughly the bytes planted,
// the payload enumerates the global and the deficit is a member-count deficit
// -- which would put this back on B52's prototype-completeness lever, recorded
// as spent. If it does not move, the payload is a fixed set of answers and the
// missing bytes are inside a handful of them, which is a different search.
//
// 100 names of 6 characters is 600 bytes of names, chosen to match the size of
// the gap being explained rather than to be subtle: this is a diagnostic run,
// not a candidate change.
(() => {
    const COUNT = 100;
    const pad = (n) => 'zz' + String(n + 1000);   // zz1000 .. zz1099, six characters each
    for (let i = 0; i < COUNT; i++) {
        try {
            Object.defineProperty(window, pad(i), {
                value: i,
                enumerable: true,
                configurable: true,
                writable: true,
            });
        } catch (e) { /* a name already taken is not worth aborting for */ }
    }
})();
