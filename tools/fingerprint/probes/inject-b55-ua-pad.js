// The positive control of the b55 padding runs.
//
// B54 measured `navigator.userAgent` plus 200 characters moving the `/tl` body
// from 18986 to 19426. Repeating it here, with the same beacon every other b55
// probe carries, does two things a remembered number cannot: it confirms the
// instrument still works in *this* sitting, and it re-measures the inflation
// factor that converts a body shortfall into a content shortfall -- the whole
// target of this plan rests on that factor being about 2.2.
//
// An overridden userAgent accessor is itself visible to whatever reads it; this
// is a diagnostic, never a candidate change.
(() => {
    let calls = 0;
    const PAD = 200;
    const real = navigator.userAgent;
    const padded = real + ' ZZ/' + 'z'.repeat(PAD - 4);
    try {
        Object.defineProperty(Navigator.prototype, 'userAgent', {
            configurable: true,
            enumerable: true,
            get() { calls++; return padded; },
        });
    } catch (e) { /* nothing to report to */ }
    setTimeout(() => {
        try { new Image().src = 'https://www.hyatt.com/__b55?p=ua&calls=' + calls; } catch (e) { /* */ }
    }, 5000);
})();
