// Does the /tl payload carry the media-capability answers?
//
// Same instrument as inject-b55-rect-pad.js: lengthen a known answer and read
// the `postLen` of the POST to `/tl`.
//
// The read log for this station has `HTMLMediaElement.canPlayType` called 36
// times with 36 distinct type strings. Chrome answers each with `probably`,
// `maybe` or the empty string, so a full set is up to about 290 characters --
// which happens to be the size of the whole shortfall being hunted, and is why
// this family is worth a run of its own rather than a line in a table.
//
// Twenty characters per call. If every answer is carried, the body should move
// by roughly 36 * 20 * 2.2, well clear of the +-32 the baseline wanders by.
(() => {
    let calls = 0;
    const PAD = 'z'.repeat(20);
    const proto = window.HTMLMediaElement && HTMLMediaElement.prototype;
    if (proto && typeof proto.canPlayType === 'function') {
        const real = proto.canPlayType;
        try {
            Object.defineProperty(proto, 'canPlayType', {
                configurable: true,
                writable: true,
                enumerable: false,
                value: function canPlayType(type) {
                    calls++;
                    return String(real.call(this, type)) + PAD;
                },
            });
        } catch (e) { /* nothing to report to */ }
    }
    setTimeout(() => {
        try { new Image().src = 'https://www.hyatt.com/__b55?p=canplaytype&calls=' + calls; } catch (e) { /* */ }
    }, 5000);
})();
