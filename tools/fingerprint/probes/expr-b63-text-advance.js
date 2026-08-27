// Where a text-derived width lands, and which readings are integers.
//
// `tl-payload-byte-attribution` attributed ~169 of the 524-character /tl
// shortfall to element geometry: "Chrome answers on its 1/64px grid where this
// engine answers whole numbers". That is this. `layout-unit-64th-grid` put
// *specified* lengths on the grid; a width that comes from measuring text still
// goes through a round to whole pixels.
//
// The pair matters as much as the values. In Chrome `offsetWidth` is an integer
// and `getBoundingClientRect().width` is not, and this engine has one dimension
// model behind both -- so a fix that only looks at the rect can round-trip
// through every offsetWidth in the suite. Both are read here, on the same
// element, so the split is measured rather than assumed.
//
// Strings chosen to land off a whole pixel at 16px: a single word, a few words,
// and a long run where a per-round fraction would accumulate.
(() => {
    const out = {};
    const host = document.createElement('div');
    // Absolutely positioned and shrink-to-fit, so the box is the text advance
    // and nothing else -- a block would fill its container and measure nothing.
    host.setAttribute('style', 'position:absolute;left:0;top:0;white-space:pre;font:16px serif');
    document.documentElement.appendChild(host);

    const strings = {
        one: 'aaa',
        word: 'word',
        two: 'aaa bbb',
        three: 'aaa bbb ccc',
        five: 'five words in a row',
        long: 'long word '.repeat(10),
        thousand: 'a'.repeat(1000),
    };

    for (const [name, text] of Object.entries(strings)) {
        host.textContent = text;
        const rect = host.getBoundingClientRect();
        out[name + '.rect'] = String(rect.width);
        out[name + '.offset'] = String(host.offsetWidth);
        out[name + '.client'] = String(host.clientWidth);
        out[name + '.scroll'] = String(host.scrollWidth);
        out[name + '.computed'] = String(getComputedStyle(host).width);
        // Is the rect on the 1/64 grid? A grid value times 64 is an integer.
        out[name + '.rect64'] = String(Number.isInteger(rect.width * 64));
    }

    // The same question for a height, which comes from the line box rather than
    // the advance: whether the two axes are quantised the same way is not
    // something to assume either.
    host.textContent = 'aaa';
    out['height.rect'] = String(host.getBoundingClientRect().height);
    out['height.offset'] = String(host.offsetHeight);
    out['height.computed'] = String(getComputedStyle(host).height);

    host.remove();
    return out;
})();
