// Is the /tl body's length a function of its content at all?
//
// P1 ruled out three shapes for the six hundred bytes this engine's payload is
// short: it does not enumerate the global, it does not fill a collection budget
// that a faster engine fills further, and the hundred and fifteen
// length-bearing answers the read log names come to -116 bytes across the two
// arms, not -600. Which leaves a possibility that changes the whole search:
// that the payload's length barely depends on what went into it, because what
// goes in is hashed or packed to a fixed width.
//
// One value settles it. `navigator.userAgent` is in every fingerprint payload
// ever written, and the read log has Kasada taking `Navigator.userAgent` here.
// Lengthen it by a known amount and watch `postLen`:
//
//   * moves by roughly the bytes added -> the body carries content at its own
//     length, and the deficit really is short answers; keep hunting them.
//   * does not move -> length is not a function of content, the six hundred
//     bytes are a *section* Chrome's payload has and ours does not, and hunting
//     short answers is hunting the wrong thing.
//
// 200 characters, well clear of the +-40 this engine's postLen wanders by
// between runs. A diagnostic, not a candidate change: an overridden userAgent
// accessor is itself visible.
(() => {
    const PAD = 200;
    const real = navigator.userAgent;
    const padded = real + ' ZZ/' + 'z'.repeat(PAD - 4);
    try {
        Object.defineProperty(Navigator.prototype, 'userAgent', {
            configurable: true,
            enumerable: true,
            get() { return padded; },
        });
    } catch (e) { /* nothing to report to: a station run has no console */ }
})();
