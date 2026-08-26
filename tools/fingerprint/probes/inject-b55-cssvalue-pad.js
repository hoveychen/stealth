// Does the /tl payload carry computed style values?
//
// Same instrument as inject-b55-rect-pad.js. The read log has
// `Window.getComputedStyle` 128 times and
// `CSSStyleDeclaration.getPropertyValue` 93 times across four property names,
// plus 52 indexed reads on a declaration. Computed style is where this engine's
// remaining measured value differences live -- a width answered `1152px` here
// against Chrome's `907.195px` -- so whether those answers reach the payload
// decides whether that family is worth an exec plan.
//
// Fifty characters per answer. The indexed form `style[name]` is not hooked:
// it goes through the declaration's own named properties rather than this
// method, so a null result here does not clear the whole family, only the
// method.
(() => {
    let calls = 0;
    const PAD = 'z'.repeat(50);
    const proto = window.CSSStyleDeclaration && CSSStyleDeclaration.prototype;
    if (proto && typeof proto.getPropertyValue === 'function') {
        const real = proto.getPropertyValue;
        try {
            Object.defineProperty(proto, 'getPropertyValue', {
                configurable: true,
                writable: true,
                enumerable: false,
                value: function getPropertyValue(name) {
                    calls++;
                    return String(real.call(this, name)) + PAD;
                },
            });
        } catch (e) { /* nothing to report to */ }
    }
    setTimeout(() => {
        try { new Image().src = 'https://www.hyatt.com/__b55?p=cssvalue&calls=' + calls; } catch (e) { /* */ }
    }, 5000);
})();
