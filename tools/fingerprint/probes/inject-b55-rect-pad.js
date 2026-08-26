// Does the /tl payload carry element geometry, and how much of it?
//
// B54 established the instrument: lengthen one answer by a known amount and
// watch the `postLen` of the POST to Kasada's `/tl`. `navigator.userAgent` plus
// 200 characters moved the body 18986 -> 19426, so the body carries its content
// at roughly 2.2x, and a value that moves it is a value that went in.
//
// Geometry is the first candidate because it is the one family where the two
// arms are already known to answer differently. The read log for this station
// (results/b53-reads-x-hyatt.json) has Kasada taking `DOMRect.width` 36 times,
// `DOMRect.height` 28, the four `DOMRectReadOnly` sides 17 each,
// `getBoundingClientRect` and `getClientRects` 18 each, `offsetWidth`/
// `offsetHeight` 15 and 17, and `clientWidth`/`clientHeight` 23 each -- around
// 130 readings of a number whose *printed length* differs between the arms,
// because Chrome's layout answers on a 1/64px grid (`907.195px`) where this
// engine answers a whole number (`1152px`).
//
// Each padded getter adds a long fractional tail, so a reading that was three
// characters becomes about eighteen. If the payload carries even a tenth of
// these, the shift is thousands of bytes and unmistakable against the +-32 this
// engine's postLen wanders by. If it does not move, geometry is not in the
// payload and the whole family can be struck off.
//
// The call counter is reported by a beacon five seconds in. The `/tl` POST goes
// out at about 800ms, so the beacon cannot be in the body it is measuring, and
// a station run has no console to report through -- antibot-sweep never sends
// Runtime.enable, because Kasada withholds clearance from a client that has.
// The count separates "the payload does not carry geometry" from "the override
// never ran".
(() => {
    let calls = 0;
    // Long enough that String() of the result grows by roughly fifteen
    // characters for a whole-number input, short enough to stay an exact double.
    const TAIL = 0.123456789012345;
    const pad = (v) => (typeof v === 'number' && isFinite(v) ? (calls++, v + TAIL) : v);

    const wrapGetters = (proto, names) => {
        if (!proto) return;
        for (const name of names) {
            const d = Object.getOwnPropertyDescriptor(proto, name);
            if (!d || !d.get) continue;
            const get = d.get;
            try {
                Object.defineProperty(proto, name, {
                    configurable: true,
                    enumerable: d.enumerable,
                    get() { return pad(get.call(this)); },
                });
            } catch (e) { /* nothing to report to */ }
        }
    };

    const BOX = ['x', 'y', 'width', 'height', 'top', 'right', 'bottom', 'left'];
    wrapGetters(window.DOMRectReadOnly && DOMRectReadOnly.prototype, BOX);
    wrapGetters(window.DOMRect && DOMRect.prototype, BOX);
    wrapGetters(window.HTMLElement && HTMLElement.prototype,
        ['offsetWidth', 'offsetHeight', 'offsetLeft', 'offsetTop']);
    wrapGetters(window.Element && Element.prototype,
        ['clientWidth', 'clientHeight', 'clientLeft', 'clientTop', 'scrollWidth', 'scrollHeight']);

    setTimeout(() => {
        try { new Image().src = 'https://www.hyatt.com/__b55?p=rect&calls=' + calls; } catch (e) { /* */ }
    }, 5000);
})();
