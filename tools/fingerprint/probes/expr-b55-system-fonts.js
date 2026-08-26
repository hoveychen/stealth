// What do the six system font keywords expand to, and what does an element
// wearing one measure?
//
// Kasada writes all six at x-hyatt — the live capture has
// `setAttribute('style', 'font: caption !important')` through
// `font: status-bar !important` in one burst, on both arms
// (tools/fingerprint/results/b55-voices-{lp,chrome}.json) — and then feeds a
// four-value readback into its payload. Chrome's is
// `100075px,155556px,165464px,305134px` and this engine's is
// `0px,0px,0px,0px`, twenty characters of the shortfall and a reading no
// browser produces.
//
// Two things are wanted: the computed longhands each keyword expands to, which
// is what `font: caption` *is*, and the width of a long string set in it, which
// is what a four-figure number that size has to be coming from.
(() => {
    const KEYWORDS = ['caption', 'icon', 'menu', 'message-box', 'small-caption', 'status-bar'];
    const LONGHANDS = ['font-style', 'font-variant', 'font-weight', 'font-stretch',
        'font-size', 'line-height', 'font-family'];
    const out = {};
    const host = document.createElement('div');
    document.body.appendChild(host);
    for (const kw of KEYWORDS) {
        const el = document.createElement('span');
        // Long enough that a per-character width difference shows up in the
        // total rather than rounding away.
        el.textContent = 'MMMMMMMMMM'.repeat(100);
        el.style.cssText = 'font: ' + kw;
        host.appendChild(el);
        const cs = getComputedStyle(el);
        out[kw] = LONGHANDS.map((p) => p + '=' + cs.getPropertyValue(p)).join('|');
        out[kw + '.font'] = cs.getPropertyValue('font');
        out[kw + '.width'] = String(el.getBoundingClientRect().width);
        el.remove();
    }
    host.remove();
    return out;
})();
